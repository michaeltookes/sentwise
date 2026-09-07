import XCTest
@testable import Sentwise

/// Managed inference client coverage for the server-minted Paddle checkout endpoint.
final class ManagedInferenceCheckoutTests: XCTestCase {

    private struct CheckoutStubSessionProvider: ManagedSessionProviding {
        var token: String = "session-jwt"

        func currentSessionToken() async throws -> String {
            token
        }
    }

    private actor CheckoutRecordingSessionProvider: ManagedSessionProviding {
        private(set) var didInvalidate = false

        func currentSessionToken() async throws -> String {
            "session-jwt"
        }

        func invalidateSession() async {
            didInvalidate = true
        }
    }

    private func json(_ string: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(string.utf8), headers: headers)
    }

    func testCreateCheckoutTransactionPostsBearerPriceAndQuantity() async throws {
        let transport = FakeLLMTransport(response: json(
            #"{"transactionId":"txn_01abc","checkoutUrl":"https://pay.example/txn_01abc"}"#
        ))
        let client = ManagedInferenceClient(
            sessionProvider: CheckoutStubSessionProvider(token: "tok-checkout"),
            transport: transport
        )

        let transaction = try await client.createCheckoutTransaction(priceID: "pri_starter")

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastURL, ManagedInference.paddleCheckoutEndpoint)
        XCTAssertEqual(transport.lastHeaders?["authorization"], "Bearer tok-checkout")
        XCTAssertEqual(transport.lastHeaders?["content-type"], "application/json")

        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["priceId"] as? String, "pri_starter")
        XCTAssertEqual(object["quantity"] as? Int, 1)

        XCTAssertEqual(transaction.transactionID, "txn_01abc")
        XCTAssertEqual(transaction.checkoutURL, "https://pay.example/txn_01abc")
    }

    func testCreateCheckoutTransactionDecodesNullCheckoutURL() async throws {
        let transport = FakeLLMTransport(response: json(#"{"transactionId":"txn_2","checkoutUrl":null}"#))
        let client = ManagedInferenceClient(sessionProvider: CheckoutStubSessionProvider(), transport: transport)

        let transaction = try await client.createCheckoutTransaction(priceID: "pri_pro")
        XCTAssertEqual(transaction.transactionID, "txn_2")
        XCTAssertNil(transaction.checkoutURL)
    }

    func testCreateCheckoutTransactionMaps401ToNotSignedInAndInvalidates() async {
        let sessionProvider = CheckoutRecordingSessionProvider()
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"unauthenticated","message":"Sign in."}}"#, status: 401
        ))
        let client = ManagedInferenceClient(sessionProvider: sessionProvider, transport: transport)

        do {
            _ = try await client.createCheckoutTransaction(priceID: "pri_pro")
            XCTFail("Expected not-signed-in error")
        } catch LLMError.managedNotSignedIn {
            let didInvalidate = await sessionProvider.didInvalidate
            XCTAssertTrue(didInvalidate)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateCheckoutTransactionSurfacesWorkerMessageForInvalidPrice() async {
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"invalid_request","message":"Unsupported Paddle price id."}}"#, status: 400
        ))
        let client = ManagedInferenceClient(sessionProvider: CheckoutStubSessionProvider(), transport: transport)

        do {
            _ = try await client.createCheckoutTransaction(priceID: "pri_bogus")
            XCTFail("Expected checkout-failed error")
        } catch LLMError.managedCheckoutFailed(let message) {
            XCTAssertEqual(message, "Unsupported Paddle price id.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateCheckoutTransactionSurfacesEligibilityConflict() async {
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"billing_subscription_active","message":"Manage your current subscription before starting a new one."}}"#,
            status: 409
        ))
        let client = ManagedInferenceClient(sessionProvider: CheckoutStubSessionProvider(), transport: transport)

        do {
            _ = try await client.createCheckoutTransaction(priceID: "pri_pro")
            XCTFail("Expected checkout-failed error")
        } catch LLMError.managedCheckoutFailed(let message) {
            XCTAssertEqual(message, "Manage your current subscription before starting a new one.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateCheckoutTransactionUnavailableFallsBackToGenericMessage() async {
        let transport = FakeLLMTransport(response: json("", status: 503))
        let client = ManagedInferenceClient(sessionProvider: CheckoutStubSessionProvider(), transport: transport)

        do {
            _ = try await client.createCheckoutTransaction(priceID: "pri_pro")
            XCTFail("Expected checkout-failed error")
        } catch LLMError.managedCheckoutFailed(let message) {
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCreateCheckoutTransactionRejectsBlankTransactionID() async {
        let transport = FakeLLMTransport(response: json(#"{"transactionId":"  ","checkoutUrl":null}"#))
        let client = ManagedInferenceClient(sessionProvider: CheckoutStubSessionProvider(), transport: transport)

        do {
            _ = try await client.createCheckoutTransaction(priceID: "pri_pro")
            XCTFail("Expected invalid-response error")
        } catch LLMError.invalidResponse {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
