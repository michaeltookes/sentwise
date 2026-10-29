import Foundation

/// Session-scoped Microsoft 365 detection by MX record
/// (`*.mail.protection.outlook.com`), for work and school domains that are not
/// one of the consumer outlook/hotmail/live domains. Mirrors
/// `GoogleWorkspaceMXDetector`: positive and negative results are cached,
/// cancellation is not evidence, and resolution is bounded by a timeout.
actor Microsoft365MXDetector {
    private let resolver: any MXRecordResolving
    private let timeoutNanoseconds: UInt64
    private var cache: [String: Bool] = [:]

    init(
        resolver: any MXRecordResolving = SystemMXRecordResolver(),
        timeoutNanoseconds: UInt64 = 1_500_000_000
    ) {
        self.resolver = resolver
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func isMicrosoft365Hosted(domain rawDomain: String) async -> Bool {
        let domain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty else { return false }
        if let cached = cache[domain] { return cached }

        let resolver = resolver
        let timeoutNanoseconds = timeoutNanoseconds
        let result: Bool
        do {
            result = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    let records = try await resolver.records(for: domain)
                    return Self.containsMicrosoft365MailExchange(records)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return false
                }
                let first = try await group.next() ?? false
                group.cancelAll()
                return first
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                return false
            }
            result = false
        }
        cache[domain] = result
        return result
    }

    nonisolated static func containsMicrosoft365MailExchange(_ records: [String]) -> Bool {
        records.contains { target in
            let normalized = target
                .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
                .lowercased()
            return normalized.hasSuffix(".mail.protection.outlook.com")
        }
    }
}

/// Combines the static domain table with the two MX detectors. Known providers
/// win without any DNS; Google Workspace is checked before Microsoft 365 so
/// Google detection is unchanged; unknown domains stay `nil` and keep today's
/// app-password path.
struct EmailProviderDetector {
    let google: GoogleWorkspaceMXDetector
    let microsoft365: Microsoft365MXDetector

    func detect(email: String) async -> EmailProviderKind? {
        if let known = EmailProviderKind.forEmail(email) { return known }
        guard let domain = EmailProviderKind.validDomain(of: email) else { return nil }
        if await google.isGoogleHosted(domain: domain) { return .gmail }
        if await microsoft365.isMicrosoft365Hosted(domain: domain) { return .microsoft }
        return nil
    }
}
