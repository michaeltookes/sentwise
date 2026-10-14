import Foundation

extension ClerkClient {
    /// The Clerk Frontend API this build signs in against (item 123): production
    /// by default, the Clerk development instance in a QA build. Used for both
    /// sign-in and session-token minting, since every request goes through
    /// `frontendAPIBaseURL`.
    static var configuredFrontendAPIBaseURL: URL { BuildConfiguration.current.clerkFrontendAPIBaseURL }

    /// A QA build without a usable Clerk development instance gets the reserved
    /// unavailable host; refuse it before any request so sign-in fails clearly
    /// and never reaches production Clerk.
    func requireAvailable() throws {
        guard frontendAPIBaseURL != BuildConfiguration.NonProductionFallback.clerkFrontendAPIURL else {
            throw ClerkError.transport("Sign-in isn't available in this build.")
        }
    }
}
