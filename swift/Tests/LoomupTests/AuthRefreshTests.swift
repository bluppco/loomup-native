import XCTest
@testable import Loomup

final class AuthRefreshTests: XCTestCase {
    func testCompletedRefreshWaiterCannotClearNewGeneration() async throws {
        let flights = RefreshFlightStore<Int>()
        let first = flights.getOrCreate { Task { 1 } }
        let firstWaiter = flights.getOrCreate { Task { 2 } }
        XCTAssertEqual(first.id, firstWaiter.id)

        _ = try await first.task.value
        flights.clear(id: first.id)

        let second = flights.getOrCreate { Task { 2 } }
        XCTAssertNotEqual(first.id, second.id)

        // A waiter from the completed generation may resume after the next
        // generation starts. Its cleanup must not clear the newer flight.
        flights.clear(id: firstWaiter.id)
        let secondWaiter = flights.getOrCreate { Task { 3 } }
        XCTAssertEqual(second.id, secondWaiter.id)
        let secondValue = try await secondWaiter.task.value
        XCTAssertEqual(secondValue, 2)
    }

    func testOn401RefreshesOnceAndRetries() async throws {
        let http = MockHTTP()
        http.handler = { method, url, auth, body in
            if url.hasSuffix("/auth/refresh") {
                return (
                    jsonData([
                        "data": [
                            "access_token": "new-access",
                            "refresh_token": "refresh-2",
                            "token_type": "Bearer",
                            "expires_in": 900,
                        ],
                    ]),
                    200
                )
            }
            if url.hasSuffix("/auth/me") {
                if auth == "Bearer old-access" {
                    return (
                        jsonData(["error": ["code": "unauthorized", "message": "expired"]]),
                        401
                    )
                }
                if auth == "Bearer new-access" {
                    return (
                        jsonData([
                            "data": [
                                "id": "u1",
                                "email": "a@b.com",
                                "role": "user",
                                "disabled": false,
                                "created_at": 1,
                            ],
                        ]),
                        200
                    )
                }
            }
            return (Data("not found".utf8), 404)
        }

        let c = createClient(
            url: URL(string: "http://example.test")!,
            token: "old-access",
            refreshToken: "refresh-1",
            http: http
        )
        let me = try await c.me()
        XCTAssertEqual(me.email, "a@b.com")
        XCTAssertEqual(c.accessToken, "new-access")
        let calls = http.snapshotCalls()
        XCTAssertTrue(calls.contains { $0.url.hasSuffix("/auth/refresh") })
        let meCalls = calls.filter { $0.url.hasSuffix("/auth/me") }
        XCTAssertEqual(meCalls.count, 2)
        XCTAssertEqual(meCalls[0].auth, "Bearer old-access")
        XCTAssertEqual(meCalls[1].auth, "Bearer new-access")
    }

    func testManualRefreshUpdatesTokens() async throws {
        let http = MockHTTP()
        http.handler = { _, url, _, _ in
            if url.hasSuffix("/auth/refresh") {
                return (
                    jsonData([
                        "data": [
                            "access_token": "a2",
                            "refresh_token": "r2",
                            "token_type": "Bearer",
                            "expires_in": 60,
                        ],
                    ]),
                    200
                )
            }
            return (Data("nope".utf8), 500)
        }
        let c = createClient(
            url: URL(string: "http://example.test")!,
            refreshToken: "r1",
            http: http
        )
        let tokens = try await c.refresh()
        XCTAssertEqual(tokens.accessToken, "a2")
        XCTAssertEqual(c.accessToken, "a2")
    }

    func testRefreshWithoutTokenThrows() async {
        let c = createClient(url: URL(string: "http://example.test")!)
        do {
            _ = try await c.refresh()
            XCTFail("expected throw")
        } catch let e as LoomupError {
            XCTAssertEqual(e.code, "no_refresh")
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testRefreshFailureIsPropagatedInsteadOfOriginalUnauthorized() async {
        let http = MockHTTP()
        http.handler = { _, url, _, _ in
            if url.hasSuffix("/auth/refresh") {
                return (
                    jsonData(["error": ["code": "unavailable", "message": "try again"]]),
                    503
                )
            }
            return (
                jsonData(["error": ["code": "unauthorized", "message": "expired"]]),
                401
            )
        }
        let client = createClient(
            url: URL(string: "http://example.test")!,
            token: "old-access",
            refreshToken: "refresh-1",
            http: http
        )

        do {
            _ = try await client.me()
            XCTFail("expected refresh failure")
        } catch let error as LoomupError {
            XCTAssertEqual(error.code, "unavailable")
            XCTAssertEqual(error.status, 503)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testConcurrentUnauthorizedRequestsShareOneRefresh() async throws {
        let refreshCount = LockedValue(0)
        let http = MockHTTP()
        http.handler = { _, url, auth, _ in
            if url.hasSuffix("/auth/refresh") {
                refreshCount.withValue { $0 += 1 }
                try await Task.sleep(nanoseconds: 20_000_000)
                return (
                    jsonData([
                        "data": [
                            "access_token": "new-access",
                            "refresh_token": "refresh-2",
                            "token_type": "Bearer",
                            "expires_in": 900,
                        ],
                    ]),
                    200
                )
            }
            if auth == "Bearer new-access" {
                return (
                    jsonData([
                        "data": [
                            "id": "u1",
                            "email": "a@b.com",
                            "role": "user",
                            "disabled": false,
                            "created_at": 1,
                        ],
                    ]),
                    200
                )
            }
            return (
                jsonData(["error": ["code": "unauthorized", "message": "expired"]]),
                401
            )
        }
        let client = createClient(
            url: URL(string: "http://example.test")!,
            token: "old-access",
            refreshToken: "refresh-1",
            http: http
        )

        async let first = client.me()
        async let second = client.me()
        _ = try await (first, second)

        XCTAssertEqual(refreshCount.snapshot(), 1)
    }
}
