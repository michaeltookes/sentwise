import Foundation
import os

private let revocationLogger = Logger(subsystem: "com.tookes.Sentwise", category: "ManagedAccountService")

extension ManagedAccountService {
    /// Fires a best-effort server-side revocation of the Clerk session and returns
    /// immediately (security finding A-L3). The network call runs detached, off the
    /// actor, so a failed or slow revocation can never block or fail local
    /// sign-out; all errors are swallowed and logged only.
    func fireServerSessionRevocation(sessionID: String, clientToken: String) {
        let clerk = self.clerk
        Task.detached {
            do {
                let response = try await clerk.revokeSession(sessionId: sessionID, clientToken: clientToken)
                if !response.isSuccess {
                    revocationLogger.error(
                        "Clerk session revocation returned HTTP \(response.statusCode, privacy: .public)"
                    )
                }
            } catch {
                revocationLogger.error(
                    "Clerk session revocation failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }
}
