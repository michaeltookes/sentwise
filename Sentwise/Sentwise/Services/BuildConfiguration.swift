import Foundation

/// Per-build configuration (sentwise item 123): which service, Clerk instance,
/// Paddle environment, Keychain service, Application Support directory, and URL
/// scheme this build of the app uses.
///
/// Production builds (the Debug and Release configurations) carry none of the
/// `Sentwise…` Info.plist keys below — they expand to empty strings — so every
/// value resolves to the compiled-in production default and nothing about an
/// existing install moves. The QA build configuration (`Config/QA.xcconfig` plus
/// its git-ignored `QA.local.xcconfig`, see docs/qa-build.md) fills the keys so a
/// QA build talks to the sandbox deployment of `sentwise-service`, opens Paddle in
/// sandbox mode, and keeps its own Keychain items, data directory, and URL
/// scheme, letting it run beside the production app on the same Mac.
///
/// Values come from a signed bundle's Info.plist, so nothing at runtime (no
/// environment variable, no defaults write) can redirect a shipped build.
struct BuildConfiguration: Equatable, Sendable {

    /// Info.plist keys, expanded at build time from the xcconfig settings named
    /// in the comments (see `Sentwise/Info.plist`).
    enum InfoKey {
        static let serviceBaseURL = "SentwiseServiceBaseURL" // SENTWISE_SERVICE_BASE_URL
        static let clerkFrontendAPIURL = "SentwiseClerkFrontendAPIURL" // SENTWISE_CLERK_FRONTEND_API_URL
        static let paddleEnvironment = "SentwisePaddleEnvironment" // SENTWISE_PADDLE_ENVIRONMENT
        static let paddleClientToken = "SentwisePaddleClientToken" // SENTWISE_PADDLE_CLIENT_TOKEN
        static let paddleStarterPriceID = "SentwisePaddleStarterPriceID" // SENTWISE_PADDLE_STARTER_PRICE_ID
        static let paddleProPriceID = "SentwisePaddleProPriceID" // SENTWISE_PADDLE_PRO_PRICE_ID
        static let paddleUnlimitedPriceID = "SentwisePaddleUnlimitedPriceID" // SENTWISE_PADDLE_UNLIMITED_PRICE_ID
        static let keychainServiceSuffix = "SentwiseKeychainServiceSuffix" // SENTWISE_KEYCHAIN_SERVICE_SUFFIX
        static let appSupportDirectoryName = "SentwiseAppSupportDirectoryName" // SENTWISE_APP_SUPPORT_DIRECTORY
        static let displayName = "CFBundleDisplayName"
        static let urlTypes = "CFBundleURLTypes"
        static let urlSchemes = "CFBundleURLSchemes"

        /// The keys whose presence marks a build as non-production.
        static let overrides = [
            serviceBaseURL, clerkFrontendAPIURL, paddleEnvironment, paddleClientToken,
            paddleStarterPriceID, paddleProPriceID, paddleUnlimitedPriceID,
            keychainServiceSuffix, appSupportDirectoryName
        ]
    }

    /// Production defaults. Changing one of these changes the shipped app.
    enum Production {
        static let serviceBaseURLString = "https://sentwise-inference.sentwise-service.workers.dev"
        static let clerkFrontendAPIURLString = "https://clerk.sentwise.ai"
        static let appSupportDirectoryName = "Sentwise"
        static let urlScheme = "sentwise"
        static let appDisplayName = "Sentwise"
    }

    /// What a non-production build falls back to when its own value is missing
    /// or malformed: never the production Keychain service or data directory.
    enum NonProductionFallback {
        static let keychainServiceSuffix = ".qa"
        static let appSupportDirectoryName = "Sentwise QA"
        static let appDisplayName = "Sentwise QA"
        /// Used when a non-production build's Clerk URL is missing, malformed, or
        /// the production instance: `.invalid` never resolves (RFC 2606) and
        /// `ClerkClient` refuses it before any request, so sign-in is unavailable
        /// rather than creating accounts in production Clerk.
        static let clerkFrontendAPIURL = URL(string: "https://clerk-unavailable.invalid")!
        /// The same for the service base URL: drafting and billing are unavailable
        /// rather than sending a non-production build's traffic to production.
        static let serviceBaseURL = URL(string: "https://service-unavailable.invalid")!
    }

    /// True for a build that carries no override keys (Debug/Release).
    let isProduction: Bool
    let serviceBaseURL: URL
    let clerkFrontendAPIBaseURL: URL
    /// False only for a non-production build without a usable, non-production
    /// Clerk Frontend API URL.
    var isSignInAvailable: Bool { clerkFrontendAPIBaseURL != NonProductionFallback.clerkFrontendAPIURL }
    /// Appended to the Keychain service (`com.tookes.Sentwise` + suffix). Empty in
    /// production.
    let keychainServiceSuffix: String
    /// Folder under `~/Library/Application Support`. `Sentwise` in production.
    let appSupportDirectoryName: String
    /// The name the status item and menu show: `Sentwise`, or the QA build's
    /// display name so the two installs are told apart.
    let appDisplayName: String
    /// The custom URL scheme this build registers (`CFBundleURLSchemes`).
    let urlScheme: String
    /// The Paddle checkout config, or nil when checkout is unavailable in this
    /// build (an incomplete or inconsistent non-production config). Never falls
    /// back to production prices in a non-production build.
    let paddle: PaddleConfig?

    /// Sparkle updates install the production release, so only production
    /// builds may start the updater.
    var allowsAutomaticUpdates: Bool { isProduction }

    /// The configuration of the running app, resolved once.
    static let current = BuildConfiguration.resolve(infoDictionary: Bundle.main.infoDictionary)

    // MARK: - Resolution

    static func resolve(infoDictionary: [String: Any]?) -> BuildConfiguration {
        let info = infoDictionary ?? [:]
        let declaredScheme = declaredURLScheme(info) ?? Production.urlScheme
        let isProduction = InfoKey.overrides.allSatisfy { string(info, $0) == nil }

        if isProduction {
            return BuildConfiguration(
                isProduction: true,
                serviceBaseURL: URL(string: Production.serviceBaseURLString)!,
                clerkFrontendAPIBaseURL: URL(string: Production.clerkFrontendAPIURLString)!,
                keychainServiceSuffix: "",
                appSupportDirectoryName: Production.appSupportDirectoryName,
                appDisplayName: Production.appDisplayName,
                urlScheme: declaredScheme,
                paddle: .production
            )
        }

        // A non-production build never talks to the production service or Clerk
        // instance: a missing, malformed, or production URL becomes unavailable.
        let serviceURL = nonProductionURL(string(info, InfoKey.serviceBaseURL), production: Production.serviceBaseURLString)
        let clerkURL = nonProductionURL(
            string(info, InfoKey.clerkFrontendAPIURL),
            production: Production.clerkFrontendAPIURLString
        )
        // Sandbox checkout needs both; otherwise checkout is unavailable.
        let pointsAwayFromProduction = serviceURL != nil && clerkURL != nil

        return BuildConfiguration(
            isProduction: false,
            serviceBaseURL: serviceURL ?? NonProductionFallback.serviceBaseURL,
            clerkFrontendAPIBaseURL: clerkURL ?? NonProductionFallback.clerkFrontendAPIURL,
            keychainServiceSuffix: keychainSuffix(string(info, InfoKey.keychainServiceSuffix)),
            appSupportDirectoryName: directoryName(string(info, InfoKey.appSupportDirectoryName)),
            appDisplayName: displayName(string(info, InfoKey.displayName)),
            urlScheme: declaredScheme,
            paddle: pointsAwayFromProduction ? sandboxPaddleConfig(info) : nil
        )
    }

    /// A complete, self-consistent Paddle sandbox config, or nil. Requires the
    /// sandbox environment, a `test_` client token, and three distinct `pri_`
    /// ids none of which is a production price id.
    private static func sandboxPaddleConfig(_ info: [String: Any]) -> PaddleConfig? {
        guard string(info, InfoKey.paddleEnvironment)?.lowercased() == PaddleEnvironment.sandbox.rawValue,
              let token = string(info, InfoKey.paddleClientToken), token.hasPrefix("test_"),
              let starter = string(info, InfoKey.paddleStarterPriceID),
              let pro = string(info, InfoKey.paddleProPriceID),
              let unlimited = string(info, InfoKey.paddleUnlimitedPriceID)
        else { return nil }
        let ids = [starter, pro, unlimited]
        let productionIDs = Set(PaddlePlan.allCases.map { PaddleConfig.production.priceID(for: $0) })
        guard ids.allSatisfy({ $0.hasPrefix("pri_") && !productionIDs.contains($0) }),
              Set(ids).count == ids.count
        else { return nil }
        return PaddleConfig(
            environment: .sandbox,
            clientSideToken: token,
            starterPriceID: starter,
            proPriceID: pro,
            unlimitedPriceID: unlimited,
            checkoutOrigin: PaddleConfig.production.checkoutOrigin
        )
    }

    // MARK: - Value parsing

    /// A trimmed, non-empty string value. An unexpanded `$(…)` (a setting the
    /// build did not define) counts as absent.
    private static func string(_ info: [String: Any], _ key: String) -> String? {
        guard let raw = info[key] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    private static func httpsURL(_ value: String?) -> URL? {
        guard let value, let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url
        else { return nil }
        return url
    }

    private static func nonProductionURL(_ value: String?, production: String) -> URL? {
        guard let url = httpsURL(value),
              url.host?.lowercased() != URL(string: production)?.host?.lowercased()
        else { return nil }
        return url
    }

    private static func displayName(_ value: String?) -> String {
        guard let value, value != Production.appDisplayName else { return NonProductionFallback.appDisplayName }
        return value
    }

    private static func keychainSuffix(_ value: String?) -> String {
        guard let value,
              value.range(of: #"^\.[A-Za-z0-9-]{1,32}$"#, options: .regularExpression) != nil
        else { return NonProductionFallback.keychainServiceSuffix }
        return value
    }

    private static func directoryName(_ value: String?) -> String {
        guard let value,
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$"#, options: .regularExpression) != nil,
              !value.contains(".."),
              value.lowercased() != Production.appSupportDirectoryName.lowercased()
        else { return NonProductionFallback.appSupportDirectoryName }
        return value
    }

    /// The first scheme in `CFBundleURLTypes`, the one macOS routes to this app.
    private static func declaredURLScheme(_ info: [String: Any]) -> String? {
        guard let types = info[InfoKey.urlTypes] as? [[String: Any]] else { return nil }
        for type in types {
            for scheme in (type[InfoKey.urlSchemes] as? [String]) ?? [] {
                let value = scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if value.range(of: #"^[a-z][a-z0-9+.-]{0,31}$"#, options: .regularExpression) != nil {
                    return value
                }
            }
        }
        return nil
    }
}
