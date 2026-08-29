import Foundation

// Wire-format DTOs for Clerk's Frontend API responses. Split out of
// `ClerkClient.swift` to keep that file within the length limit (item 59).
// Module-internal (not file-private) so the client's decode helpers can reach
// them from the split file.

struct SignInEnvelope: Decodable {
    let response: SignInResource?
    let errors: [ClerkAPIError]?
}

struct SignInResource: Decodable {
    let id: String?
    let status: String?
    let createdSessionId: String?
    let supportedFirstFactors: [FirstFactor]?
    /// Sign-up only: fields Clerk still requires (e.g. `password` when the
    /// instance is misconfigured for a passwordless product).
    let missingFields: [String]?
    /// The identifier (email) Clerk associated with the sign-in, when present.
    let identifier: String?
    /// OAuth sign-ins carry the hosted redirect URL here.
    let firstFactorVerification: OAuthVerification?

    enum CodingKeys: String, CodingKey {
        case id, status, identifier
        case createdSessionId = "created_session_id"
        case supportedFirstFactors = "supported_first_factors"
        case missingFields = "missing_fields"
        case firstFactorVerification = "first_factor_verification"
    }
}

struct OAuthVerification: Decodable {
    let externalVerificationRedirectURL: String?

    enum CodingKeys: String, CodingKey {
        case externalVerificationRedirectURL = "external_verification_redirect_url"
    }
}

struct FirstFactor: Decodable {
    let strategy: String?
    let emailAddressId: String?

    enum CodingKeys: String, CodingKey {
        case strategy
        case emailAddressId = "email_address_id"
    }
}

struct TokenEnvelope: Decodable {
    let jwt: String?
}

struct SessionJWTPayload: Decodable {
    let sub: String?
}

enum ClerkJWT {
    static func subject(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2,
              let payload = base64URLData(from: parts[1]),
              let decoded = try? JSONDecoder().decode(SessionJWTPayload.self, from: payload),
              let subject = decoded.sub?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subject.isEmpty
        else {
            return nil
        }
        return subject
    }

    private static func base64URLData(from encoded: Substring) -> Data? {
        var base64 = String(encoded)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        switch base64.count % 4 {
        case 0:
            break
        case 2:
            base64 += "=="
        case 3:
            base64 += "="
        default:
            return nil
        }
        return Data(base64Encoded: base64)
    }
}

struct ErrorsEnvelope: Decodable {
    let errors: [ClerkAPIError]?
}

struct ClerkAPIError: Decodable {
    let message: String?
    let longMessage: String?
    let code: String?

    enum CodingKeys: String, CodingKey {
        case message
        case longMessage = "long_message"
        case code
    }
}
