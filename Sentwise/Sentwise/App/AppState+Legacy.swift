import Foundation
import os

private let legacyLogger = Logger(subsystem: "com.tookes.Sentwise", category: "AppState.Legacy")

/// Cleanup of the parked Gmail-OAuth credentials. Kept in a separate file so
/// `AppState` stays within the file/type length limits.
extension AppState {

    static let legacyOAuthKeys: [SecretKey] = [
        .gmailToken,
        .googleClientID,
        .googleClientSecret
    ]

    func cleanupLegacyOAuthCredentials() {
        do {
            try removeLegacyOAuthCredentialsIfPresent()
        } catch {
            setAppWideConnectionError(Self.legacyOAuthCleanupMessage(error: error))
        }
    }

    func removeLegacyOAuthCredentialsIfPresent() throws {
        var removedAnyCredential = false
        for key in Self.legacyOAuthKeys where try secrets.value(for: key) != nil {
            try secrets.remove(key)
            removedAnyCredential = true
        }

        if removedAnyCredential {
            legacyLogger.info("Legacy Gmail OAuth credentials removed")
        }
    }
}
