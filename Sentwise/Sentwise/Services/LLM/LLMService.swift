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
        let quotaAccountKey = provider == .managed
            ? await quotaReporter?.currentQuotaReportAccountKey()
            : nil
        let response = try await client(for: provider, apiKey: apiKey, baseURL: baseURL).complete(request)
        // Surface the latest allotment from the draft response (item 56b).
        if provider == .managed, let quota = response.quota, let quotaAccountKey {
            await quotaReporter?.reportQuota(quota, accountKey: quotaAccountKey)
        }
        return response
    }

    /// Fetches the managed account's current status from `/v1/me` (item 56b). In
    /// Prowl hunt mode returns a fixed quota with no account id and zero network.
    /// The status is returned to the caller (which ingests it) — the relay is
    /// reserved for the draft path, where the response is otherwise swallowed by
    /// the generators — so this does not double-report.
    func fetchManagedAccountStatus() async throws -> ManagedAccountStatus? {
        if isProwlHuntMode {
            return StubManagedInferenceClient.stubbedAccountStatus
        }
        let client = ManagedInferenceClient(
            sessionProvider: managedSessionProvider,
            transport: transport
        )
        return try await client.fetchAccountStatus()
    }

    /// Fetches only the managed account's current usage allotment from `/v1/me`.
    func fetchManagedQuota() async throws -> ManagedQuota? {
        try await fetchManagedAccountStatus()?.quota
    }

    /// Deletes the managed account via `DELETE /v1/me` (item 73). In Prowl hunt
    /// mode this is a deterministic, zero-network no-op so the confirm flow can be
    /// walked without touching a real account.
    func deleteManagedAccount() async throws {
        if isProwlHuntMode { return }
        let client = ManagedInferenceClient(
            sessionProvider: managedSessionProvider,
            transport: transport
        )
        try await client.deleteAccount()
    }

    /// Mints a server-side Paddle checkout transaction via
    /// `POST /v1/paddle/checkout` (item 56c). In Prowl hunt mode returns a
    /// deterministic stub transaction with zero network so hunts stay offline-safe
    /// (the overlay is never actually opened in a hunt).
    func createPaddleCheckoutTransaction(priceID: String) async throws -> PaddleCheckoutTransaction {
        if isProwlHuntMode {
            return PaddleCheckoutTransaction(transactionID: "txn_hunt_stub")
        }
        let client = ManagedInferenceClient(
            sessionProvider: managedSessionProvider,
            transport: transport
        )
        return try await client.createCheckoutTransaction(priceID: priceID)
    }

    /// Fetches a fresh Paddle management URL via `GET /v1/paddle/manage-billing`
    /// (item 90). In Prowl hunt mode returns a deterministic, zero-network stub
    /// URL so the pane's control is reachable without touching the network (the
    /// browser is never actually opened in a hunt — `AppState` gates that).
    func fetchManageBillingURL(action: PaddleBillingAction?) async throws -> URL {
        if isProwlHuntMode {
            return URL(string: "https://sentwise.ai/account/billing")!
        }
        let client = ManagedInferenceClient(
            sessionProvider: managedSessionProvider,
            transport: transport
        )
        return try await client.fetchManageBillingURL(action: action)
    }

    /// Switches the managed subscription's tier via `POST /v1/paddle/change-plan`
    /// (item 90). In Prowl hunt mode returns a deterministic, zero-network result
    /// for the requested tier so the confirm→reconcile flow is walkable offline.
    func changeManagedPlan(priceID: String) async throws -> PaddlePlanChange {
        if isProwlHuntMode {
            let plan = PaddleConfig.active.plan(forPriceID: priceID)?.subscriptionPlan ?? .unknown
            return PaddlePlanChange(plan: plan, status: .active)
        }
        let client = ManagedInferenceClient(
            sessionProvider: managedSessionProvider,
            transport: transport
        )
        return try await client.changePlan(priceID: priceID)
    }
}
