import XCTest
@testable import Loomup

private actor MockAppIntegrityProvider: AppIntegrityProvider {
    private var requests: [AppIntegrityRequest] = []

    func prepareGrant(for request: AppIntegrityRequest) async throws -> String {
        requests.append(request)
        return "grant-\(requests.count)"
    }

    func snapshot() -> [AppIntegrityRequest] { requests }
}

final class AppIntegrityTests: XCTestCase {
    func testMutationGrantBindsExactBytesAndAuthorization() async throws {
        let http = MockHTTP()
        http.handler = { _, _, _, _ in
            (jsonData(["data": ["id": 1, "title": "secured"]]), 200)
        }
        let integrity = MockAppIntegrityProvider()
        let client = createClient(
            url: URL(string: "https://example.test")!,
            token: "access-token",
            appIntegrityProvider: integrity,
            http: http
        )

        _ = try await client.from("todos").insert(["title": .string("secured")])

        let requests = await integrity.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, "POST")
        XCTAssertEqual(requests[0].pathAndQuery, "/api/todos")
        XCTAssertEqual(requests[0].authorizationToken, "access-token")
        XCTAssertEqual(requests[0].bodySHA256, AppIntegrityRequest(
            method: "POST",
            pathAndQuery: "/api/todos",
            body: requests[0].body,
            authorizationToken: nil
        ).bodySHA256)

        let calls = http.snapshotCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].body, requests[0].body)
        XCTAssertEqual(calls[0].appGrant, "grant-1")
    }

    func testRequiredResponseObtainsOneFreshGrantAndRetriesOnce() async throws {
        let http = MockHTTP()
        http.handler = { _, _, _, _ in
            if http.snapshotCalls().count == 1 {
                return (jsonData(["error": [
                    "code": "app_integrity_required",
                    "message": "fresh proof required",
                ]]), 403)
            }
            return (jsonData(["data": ["id": 1]]), 200)
        }
        let integrity = MockAppIntegrityProvider()
        let client = createClient(
            url: URL(string: "https://example.test")!,
            appIntegrityProvider: integrity,
            http: http
        )

        _ = try await client.from("todos").delete(1)

        let requests = await integrity.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(http.snapshotCalls().map(\.appGrant), ["grant-1", "grant-2"])
    }

    func testGrantBindsNormalizedBackendTargetWithoutProxyBasePath() async throws {
        let http = MockHTTP()
        http.handler = { _, _, _, _ in (jsonData(["data": ["ok": true]]), 200) }
        let integrity = MockAppIntegrityProvider()
        let client = createClient(
            url: URL(string: "https://example.test/edge")!,
            appIntegrityProvider: integrity,
            http: http
        )

        _ = try await client.request(
            method: "DELETE",
            path: "/api/todos?label=hello world"
        )

        let requests = await integrity.snapshot()
        XCTAssertEqual(requests.single?.pathAndQuery, "/api/todos?label=hello%20world")
    }
}

private extension Array {
    var single: Element? { count == 1 ? self[0] : nil }
}
