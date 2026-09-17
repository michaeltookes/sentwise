import Foundation

/// A `LocalizedError` used by the persistence test doubles to drive write-failure
/// and purge-failure paths deterministically.
enum AppStatePersistenceError: LocalizedError {
    case writeDenied

    var errorDescription: String? {
        switch self {
        case .writeDenied:
            return "settings write denied"
        }
    }
}
