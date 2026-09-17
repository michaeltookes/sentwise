import XCTest
@testable import Sentwise

/// The pure tier→account-cap mapping (item 99, docs/tier-matrix.md).
final class AccountConnectionLimitTests: XCTestCase {

    func testCapsMatchTierMatrix() {
        XCTAssertEqual(AccountConnectionLimit.maxConnectedAccounts(for: .starter), 1)
        XCTAssertEqual(AccountConnectionLimit.maxConnectedAccounts(for: .pro), 2)
        XCTAssertEqual(AccountConnectionLimit.maxConnectedAccounts(for: .unlimited), 5)
        XCTAssertEqual(AccountConnectionLimit.maxConnectedAccounts(for: .trial), 2)
    }

    func testReservedAndUnknownPlansFallBackLeniently() {
        XCTAssertEqual(AccountConnectionLimit.maxConnectedAccounts(for: .team), 2)
        XCTAssertEqual(AccountConnectionLimit.maxConnectedAccounts(for: .noPlan), AccountConnectionLimit.defaultLimit)
        XCTAssertEqual(AccountConnectionLimit.maxConnectedAccounts(for: .unknown), AccountConnectionLimit.defaultLimit)
        XCTAssertEqual(AccountConnectionLimit.maxConnectedAccounts(for: nil), AccountConnectionLimit.defaultLimit)
        XCTAssertEqual(AccountConnectionLimit.defaultLimit, 2)
    }
}
