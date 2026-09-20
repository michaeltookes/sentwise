import Foundation
import os

private let credentialEnvironmentLogger = Logger(
    subsystem: "com.tookes.Sentwise",
    category: "ManagedAccountService"
)

extension ManagedAccountService {
    func persistClientToken(_ token: String) throws {
        guard !token.isEmpty else { return }
        try persistClerkCredentialEnvironmentMarker()
        try secrets.set(token, for: .managedClientToken)
    }

    func persistClerkCredentialEnvironmentMarker() throws {
        try secrets.set(clerk.frontendAPIBaseURL.absoluteString, for: .managedClerkFrontendAPIBaseURL)
    }

    private func clearClerkCredentialEnvironmentMarker() throws {
        try secrets.remove(.managedClerkFrontendAPIBaseURL)
    }

    @discardableResult
    func clearClerkCredentialEnvironmentMarkerBestEffort(context: String) -> Error? {
        do {
            try clearClerkCredentialEnvironmentMarker()
            return nil
        } catch {
            credentialEnvironmentLogger.error(
                "Failed to clear managed Clerk environment marker \(context): \(error.localizedDescription)"
            )
            return error
        }
    }
}
