import Foundation

/// Resolves the selected provider + API key into a concrete `LLMClient` and
/// exposes the operations the app needs. Production entry point for the LLM
/// layer; `AppState` talks to it through `LLMProviding`.
struct LLMService: LLMProviding {
    let transport: LLMHTTPTransport
    /// Supplies fresh account session tokens for the managed provider. Defaults
    /// to an "unavailable" provider so a service built without an account wired
    /// in reports "not signed in" rather than crashing.
    let managedSessionProvider: ManagedSessionProviding
    /// Receives the latest managed quota after each draft/`/v1/me` fetch so the
    /// app can mirror it into observable state and drive usage alerts (item 56b).
    let quotaReporter: ManagedQuotaReporting?
    /// When true, the managed provider returns a canned, zero-network response so
    /// Prowl accessibility hunts stay offline-safe (backlog 56a).
    let isProwlHuntMode: Bool

    init(
        transport: LLMHTTPTransport = URLSessionTransport(),
        managedSessionProvider: ManagedSessionProviding = UnavailableManagedSessionProvider(),
        quotaReporter: ManagedQuotaReporting? = nil,
        isProwlHuntMode: Bool = ProwlHuntRuntime.current.isEnabled
    ) {
        self.transport = transport
        self.managedSessionProvider = managedSessionProvider
        self.quotaReporter = quotaReporter
        self.isProwlHuntMode = isProwlHuntMode
    }

    /// Builds the adapter for a provider. `baseURL` is honored only by adapters
    /// whose `supportsCustomBaseURL` is true (the OpenAI-compatible and local
    /// ones); other adapters ignore it.
    private func client(for provider: LLMProviderKind, apiKey: String, baseURL: String?) -> LLMClient {
        switch provider {
        case .managed:
            // Hunt mode: never touch the network or the session provider.
            if isProwlHuntMode {
                return StubManagedInferenceClient()
            }
            return ManagedInferenceClient(
                sessionProvider: managedSessionProvider,
                transport: transport
            )
        case .anthropic:
            return AnthropicClient(apiKey: apiKey, transport: transport)
        case .openAICompatible, .ollama:
            // One adapter serves both: the local provider only differs by its
            // default endpoint (Ollama's loopback) and key-optional auth.
            return OpenAICompatibleClient(
                apiKey: apiKey,
                transport: transport,
                baseURL: baseURL,
                defaultEndpoint: provider.defaultOpenAICompatibleEndpoint ?? OpenAICompatibleClient.defaultEndpoint,
                requiresAPIKey: provider.requiresAPIKey
            )
        }
    }

    /// Verifies credentials with a tiny, cheap request.
    func testConnection(
        provider: LLMProviderKind,
        apiKey: String,
        model: String,
        baseURL: String?
    ) async throws {
        let request = LLMRequest(
            messages: [LLMMessage(role: .user, content: "Reply with the single word: OK")],
            model: model,
            maxTokens: 16,
            temperature: 0
        )
        _ = try await client(for: provider, apiKey: apiKey, baseURL: baseURL).complete(request)
    }

    /// Runs a completion against the selected provider. (Used by the draft
    /// engine in a later slice.)
    func complete(
        _ request: LLMRequest,
        provider: LLMProviderKind,
        apiKey: String,
        baseURL: String?
    ) async throws -> LLMResponse {
        let response = try await client(for: provider, apiKey: apiKey, baseURL: baseURL).complete(request)
        // Surface the latest allotment from the draft response (item 56b).
        if let quota = response.quota {
            await quotaReporter?.reportQuota(quota)
        }
        return response
    }

    /// Fetches the managed account's current usage allotment from `/v1/me`
    /// (item 56b) and reports it to the sink. In Prowl hunt mode returns a fixed
    /// stub with zero network. Returns `nil` for a non-managed setup or when the
    /// Worker omits `quota` (older build).
    func fetchManagedQuota() async throws -> ManagedQuota? {
        if isProwlHuntMode {
            let stub = StubManagedInferenceClient.stubbedQuota
            await quotaReporter?.reportQuota(stub)
            return stub
        }
        let client = ManagedInferenceClient(
            sessionProvider: managedSessionProvider,
            transport: transport
        )
        let quota = try await client.fetchAccountQuota()
        if let quota {
            await quotaReporter?.reportQuota(quota)
        }
        return quota
    }
}
