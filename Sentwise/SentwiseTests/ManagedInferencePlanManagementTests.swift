import XCTest
@testable import Sentwise

/// Managed-inference client coverage for the item-90 plan-management endpoints:
/// on-demand `GET /v1/paddle/manage-billing` and `POST /v1/paddle/change-plan`.
final class ManagedInferencePlanManagementTests: XCTestCase {

    private struct StubSessionProvider: ManagedSessionProviding {
        var token: String = "session-jwt"
        func currentSessionToken() async throws -> String { token }
    }

    private actor RecordingSessionProvider: ManagedSessionProviding {
        private(set) var didInvalidate = false
        func currentSessionToken() async throws -> String { "session-jwt" }
        func invalidateSession() async { didInvalidate = true }
    }

    private func json(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(string.utf8), headers: [:])
    }

    // MARK: - Manage billing (on-demand URL)

    func testFetchManageBillingURLGetsBearerDefaultEndpointAndDecodesURL() async throws {
        let transport = FakeLLMTransport(response: json(#"{"managementUrl":"https://billing.example/portal"}"#))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(token: "tok-mb"), transport: transport)

        let url = try await client.fetchManageBillingURL()

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastURL, ManagedInference.paddleManageBillingEndpoint)
        XCTAssertEqual(transport.lastHeaders?["authorization"], "Bearer tok-mb")
        XCTAssertEqual(url.absoluteString, "https://billing.example/portal")
    }

    func testFetchManageBillingURLAppendsCancelActionQuery() async throws {
        let transport = FakeLLMTransport(response: json(#"{"managementUrl":"https://billing.example/cancel"}"#))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)

        let url = try await client.fetchManageBillingURL(action: .cancel)

        let last = try XCTUnwrap(transport.lastURL)
        XCTAssertTrue(last.absoluteString.hasSuffix("/v1/paddle/manage-billing?action=cancel"), last.absoluteString)
        XCTAssertEqual(url.absoluteString, "https://billing.example/cancel")
    }

    func testFetchManageBillingURLMaps401ToNotSignedInAndInvalidates() async {
        let sessionProvider = RecordingSessionProvider()
        let transport = FakeLLMTransport(response: json(#"{"error":{"type":"unauthenticated","message":"Sign in."}}"#, status: 401))
        let client = ManagedInferenceClient(sessionProvider: sessionProvider, transport: transport)

        do {
            _ = try await client.fetchManageBillingURL()
            XCTFail("Expected not-signed-in error")
        } catch LLMError.managedNotSignedIn {
            let didInvalidate = await sessionProvider.didInvalidate
            XCTAssertTrue(didInvalidate)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchManageBillingURLSurfacesWorkerMessageOnError() async {
        let transport = FakeLLMTransport(response: json(
            #"{"error":{"type":"billing_subscription_not_found","message":"No active subscription to manage."}}"#,
            status: 404
        ))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)

        do {
            _ = try await client.fetchManageBillingURL()
            XCTFail("Expected unavailable error")
        } catch LLMError.managedManageBillingUnavailable(let message) {
            XCTAssertEqual(message, "No active subscription to manage.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchManageBillingURLRejectsBlankOrNonHTTPURL() async {
        for body in [#"{"managementUrl":"   "}"#, #"{"managementUrl":"ftp://x/y"}"#, #"{"managementUrl":null}"#] {
            let transport = FakeLLMTransport(response: json(body))
            let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)
            do {
                _ = try await client.fetchManageBillingURL()
                XCTFail("Expected unavailable error for body \(body)")
            } catch LLMError.managedManageBillingUnavailable {
                // expected
            } catch {
                XCTFail("Unexpected error for body \(body): \(error)")
            }
        }
    }

    // MARK: - Change plan

    func testChangePlanPostsBearerPriceIdAndDecodesResult() async throws {
        let transport = FakeLLMTransport(response: json(#"{"ok":true,"plan":"pro","status":"active"}"#))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(token: "tok-cp"), transport: transport)

        let change = try await client.changePlan(priceID: "pri_pro")

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastURL, ManagedInference.paddleChangePlanEndpoint)
        XCTAssertEqual(transport.lastHeaders?["authorization"], "Bearer tok-cp")
        let body = try XCTUnwrap(transport.lastBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["priceId"] as? String, "pri_pro")
        XCTAssertEqual(change, PaddlePlanChange(plan: .pro, status: .active))
    }

    func testChangePlanDecodesUnknownPlanAsFallback() async throws {
        let transport = FakeLLMTransport(response: json(#"{"ok":true,"plan":"enterprise","status":"active"}"#))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)

        let change = try await client.changePlan(priceID: "pri_x")
        XCTAssertEqual(change.plan, .unknown)
        XCTAssertEqual(change.status, .active)
    }

    func testChangePlanMaps401ToNotSignedInAndInvalidates() async {
        let sessionProvider = RecordingSessionProvider()
        let transport = FakeLLMTransport(response: json(#"{"error":{"type":"unauthenticated","message":"Sign in."}}"#, status: 401))
        let client = ManagedInferenceClient(sessionProvider: sessionProvider, transport: transport)

        do {
            _ = try await client.changePlan(priceID: "pri_pro")
            XCTFail("Expected not-signed-in error")
        } catch LLMError.managedNotSignedIn {
            let didInvalidate = await sessionProvider.didInvalidate
            XCTAssertTrue(didInvalidate)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testChangePlanSurfacesWorkerMessageForEachError() async {
        let cases: [(Int, String, String)] = [
            (
                400,
                #"{"error":{"type":"invalid_request","message":"You're already on that plan."}}"#,
                "You're already on that plan."
            ),
            (
                404,
                #"{"error":{"type":"billing_subscription_not_found","message":"No active subscription to change."}}"#,
                "No active subscription to change."
            ),
            (
                502,
                #"{"error":{"type":"upstream_error","message":"Billing is temporarily unavailable."}}"#,
                "Billing is temporarily unavailable."
            ),
            (
                503,
                #"{"error":{"type":"checkout_unavailable","message":"Plan changes are unavailable right now."}}"#,
                "Plan changes are unavailable right now."
            )
        ]
        for (status, body, expected) in cases {
            let transport = FakeLLMTransport(response: json(body, status: status))
            let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)
            do {
                _ = try await client.changePlan(priceID: "pri_pro")
                XCTFail("Expected change-plan-failed for status \(status)")
            } catch LLMError.managedChangePlanFailed(let message) {
                XCTAssertEqual(message, expected, "status \(status)")
            } catch {
                XCTFail("Unexpected error for status \(status): \(error)")
            }
        }
    }

    func testChangePlanFallsBackToGenericMessageWhenBodyEmpty() async {
        let transport = FakeLLMTransport(response: json("", status: 502))
        let client = ManagedInferenceClient(sessionProvider: StubSessionProvider(), transport: transport)
        do {
            _ = try await client.changePlan(priceID: "pri_pro")
            XCTFail("Expected change-plan-failed error")
        } catch LLMError.managedChangePlanFailed(let message) {
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
