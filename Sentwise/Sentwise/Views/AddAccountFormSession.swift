import Foundation

/// The Settings "Add another account" form's session (item 104).
///
/// Every time the form opens or closes the session gets a new identifier. A
/// connection flow captures `id` when it starts and applies its result only
/// while `accepts(_:)` still holds, so a Google sign-in started in a form the
/// user cancelled can never be adopted by a form opened again before the
/// browser returned.
struct AddAccountFormSession: Equatable {
    private(set) var isActive = false
    private(set) var id = UUID()

    /// Opens a new add-account session.
    mutating func begin() {
        isActive = true
        id = UUID()
    }

    /// Closes the current add-account session; a no-op when none is open, so
    /// a flow started outside the add form keeps its result.
    mutating func end() {
        guard isActive else { return }
        isActive = false
        id = UUID()
    }

    /// Whether a flow that captured `sessionID` may still apply its result.
    func accepts(_ sessionID: UUID) -> Bool {
        sessionID == id
    }
}
