struct DraftLLMConfiguration: Equatable {
    let provider: LLMProviderKind
    let model: String
    let apiKey: String
    let baseURL: String?
}
