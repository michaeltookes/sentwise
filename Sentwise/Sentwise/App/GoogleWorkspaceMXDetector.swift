import dnssd
import Foundation

protocol MXRecordResolving: Sendable {
    func records(for domain: String) async throws -> [String]
}

/// Resolves MX records through the system DNS service. No HTTP service or
/// third-party endpoint is involved.
struct SystemMXRecordResolver: MXRecordResolving {
    func records(for domain: String) async throws -> [String] {
        let query = DNSMXQuery()
        return try await withTaskCancellationHandler {
            try await query.start(domain: domain)
        } onCancel: {
            query.cancel()
        }
    }
}

/// Session-scoped Google Workspace detection. Both successful and negative
/// results are cached so repeated edits of the same domain do not repeat DNS.
actor GoogleWorkspaceMXDetector {
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

    func isGoogleHosted(domain rawDomain: String) async -> Bool {
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
                    return Self.containsGoogleMailExchange(records)
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
            result = false
        }
        cache[domain] = result
        return result
    }

    nonisolated static func containsGoogleMailExchange(_ records: [String]) -> Bool {
        records.contains { target in
            let normalized = target
                .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
                .lowercased()
            return normalized == "google.com"
                || normalized.hasSuffix(".google.com")
                || normalized == "googlemail.com"
                || normalized.hasSuffix(".googlemail.com")
        }
    }
}

private final class DNSMXQuery: @unchecked Sendable {
    /// DNSServiceSetDispatchQueue requires a serial queue. Registration,
    /// callbacks, cancellation and deallocation all stay on this queue.
    private let queue = DispatchQueue(label: "ai.sentwise.mx-query", qos: .utility)
    private var continuation: CheckedContinuation<[String], Error>?
    private var service: DNSServiceRef?
    private var targets: [String] = []
    private var isFinished = false

    func start(domain: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.begin(domain: domain, continuation: continuation) }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func begin(domain: String, continuation: CheckedContinuation<[String], Error>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isFinished else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation

        var service: DNSServiceRef?
        let error = DNSServiceQueryRecord(
            &service,
            0,
            0,
            domain,
            UInt16(kDNSServiceType_MX),
            UInt16(kDNSServiceClass_IN),
            Self.callback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        self.service = service
        guard error == kDNSServiceErr_NoError, let service else {
            finish(.failure(MXResolverError.queryFailed(error)))
            return
        }
        let queueError = DNSServiceSetDispatchQueue(service, queue)
        guard queueError == kDNSServiceErr_NoError else {
            finish(.failure(MXResolverError.queryFailed(queueError)))
            return
        }
    }

    private func receive(flags: DNSServiceFlags, error: DNSServiceErrorType, length: UInt16, data: UnsafeRawPointer?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard error == kDNSServiceErr_NoError else {
            finish(.failure(MXResolverError.queryFailed(error)))
            return
        }
        if let target = Self.decodeMXTarget(length: length, data: data) {
            targets.append(target)
        }
        if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 {
            finish(.success(targets))
        }
    }

    private func finish(_ result: Result<[String], Error>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isFinished else { return }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        let service = service
        self.service = nil
        if let service { DNSServiceRefDeallocate(service) }
        continuation?.resume(with: result)
    }

    private static let callback: DNSServiceQueryRecordReply = { _, flags, _, error, _, _, _, length, data, _, context in
        guard let context else { return }
        Unmanaged<DNSMXQuery>.fromOpaque(context).takeUnretainedValue().receive(
            flags: flags,
            error: error,
            length: length,
            data: data
        )
    }

    private static func decodeMXTarget(length: UInt16, data: UnsafeRawPointer?) -> String? {
        guard let data, length > 3 else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var index = 2 // MX preference precedes the DNS-encoded exchange name.
        var labels: [String] = []
        while index < Int(length) {
            let labelLength = Int(bytes[index])
            index += 1
            if labelLength == 0 { return labels.isEmpty ? nil : labels.joined(separator: ".") }
            // Compressed pointers cannot be decoded without the original packet;
            // DNSServiceQueryRecord normally returns expanded record data.
            guard labelLength & 0xC0 == 0,
                  index + labelLength <= Int(length) else { return nil }
            let labelData = Data(bytes: bytes + index, count: labelLength)
            guard let label = String(data: labelData, encoding: .utf8) else { return nil }
            labels.append(label)
            index += labelLength
        }
        return nil
    }
}

private enum MXResolverError: Error {
    case queryFailed(DNSServiceErrorType)
}
