import SentwiseMail
import XCTest
@testable import Sentwise

/// Verifies the inline row-expansion accordion on `ReviewWindowSelection`
/// (item 82): toggling an identity expands it, toggling the same one collapses
/// back to `nil`, and toggling a different one replaces it — so at most one draft
/// row is ever expanded at a time.
@MainActor
final class ReviewWindowSelectionTests: XCTestCase {

    func testTogglingAnIdentityExpandsIt() {
        let selection = ReviewWindowSelection()
        XCTAssertNil(selection.expandedDraftIdentity)

        selection.toggleExpanded("a")

        XCTAssertEqual(selection.expandedDraftIdentity, "a")
    }

    func testTogglingTheSameIdentityCollapsesIt() {
        let selection = ReviewWindowSelection()
        selection.toggleExpanded("a")

        selection.toggleExpanded("a")

        XCTAssertNil(selection.expandedDraftIdentity, "toggling the open row collapses it")
    }

    func testTogglingADifferentIdentityReplacesTheExpandedOne() {
        let selection = ReviewWindowSelection()
        selection.toggleExpanded("a")

        selection.toggleExpanded("b")

        XCTAssertEqual(selection.expandedDraftIdentity, "b", "only one row is expanded at a time")
    }

    func testExpansionStartsCollapsed() {
        let selection = ReviewWindowSelection(selectedTab: .drafts)

        XCTAssertNil(selection.expandedDraftIdentity)
    }
}
