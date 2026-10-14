import Foundation
@testable import Sentwise

extension PaddleConfig {
    /// The Paddle sandbox catalog used by tests and the live overlay test
    /// (`PaddleCheckoutLiveTests`). Test-target only: production builds carry no
    /// sandbox credentials, and QA builds read theirs from Info.plist
    /// (`BuildConfiguration`, item 123). The client-side token is public by
    /// design (frontend-scoped).
    static let testSandbox = PaddleConfig(
        environment: .sandbox,
        clientSideToken: "test_7a55409b65e7f906b94b863e63a",
        starterPriceID: "pri_01m1syd7nfarp8pggpcnvjbgyy",
        proPriceID: "pri_01m1symsxarc4c3jdea0ntb09w",
        unlimitedPriceID: "pri_01m1syrdg05f49kz705gbzn6tz",
        checkoutOrigin: URL(string: "https://sentwise.ai")!
    )
}
