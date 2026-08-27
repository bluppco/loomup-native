import XCTest
@testable import Loomup

final class RealtimeTests: XCTestCase {
    func testMatchingApplicationPongKeepsSocketHealthy() async throws {
        let box = MockWebSocketBox()
        let factory: WebSocketFactory = {
            let ws = MockWebSocket()
            echoHeartbeatPongs(on: ws)
            box.note(ws)
            return ws
        }
        let c = createClient(
            url: URL(string: "http://example.test")!,
            webSocketFactory: factory,
            realtimeHeartbeat: RealtimeHeartbeatOptions(
                intervalMs: 20,
                responseTimeoutMs: 35
            )
        )
        let controls = LockedValue<[ControlEvent]>([])
        let off = c.onControl { event in
            controls.withValue { $0.append(event) }
        }
        let unsub = c.from("todos").subscribe { _ in }

        let receivedMultiplePings = await waitUntil(timeoutMs: 250) {
            (box.socket?.parsedSent().filter { ($0["type"] as? String) == "ping" }.count ?? 0) >= 2
        }
        XCTAssertTrue(receivedMultiplePings)
        XCTAssertEqual(box.sockets.count, 1)

        let pings = box.socket?.parsedSent().filter { ($0["type"] as? String) == "ping" } ?? []
        XCTAssertTrue(pings.allSatisfy {
            (($0["requestId"] as? String)?.hasPrefix("hb_") ?? false)
                && $0["sentAt"] is NSNumber
        })
        XCTAssertFalse(controls.snapshot().contains { $0.type == "pong" })
        off()
        unsub()
        c.closeRealtime()
    }

    func testMissingPongRetiresOpenSocketReconnectsAndResyncsOnce() async throws {
        let http = MockHTTP()
        http.handler = { _, url, _, _ in
            if url.contains("/api/todos/7") {
                return (jsonData(["data": ["id": 7, "title": "recovered"]]), 200)
            }
            return (Data("nope".utf8), 404)
        }
        let box = MockWebSocketBox()
        let ordinal = LockedValue(0)
        let factory: WebSocketFactory = {
            let ws = MockWebSocket()
            let number = ordinal.withValue {
                $0 += 1
                return $0
            }
            if number > 1 {
                echoHeartbeatPongs(on: ws)
            }
            box.note(ws)
            return ws
        }
        let events = LockedValue<[ChangeEvent]>([])
        let c = createClient(
            url: URL(string: "http://example.test")!,
            token: "access-token",
            http: http,
            webSocketFactory: factory,
            realtimeHeartbeat: RealtimeHeartbeatOptions(
                intervalMs: 15,
                responseTimeoutMs: 25
            )
        )
        let unsub = c.from("todos").subscribe(rowId: "7") { event in
            events.withValue { $0.append(event) }
        }
        let firstOpened = await waitUntil(timeoutMs: 150) { box.socket?.isOpen == true }
        XCTAssertTrue(firstOpened)
        guard let first = box.socket else {
            XCTFail("expected initial socket")
            return
        }
        let lateClose = first.onClose
        let lateMessage = first.onMessage

        let reconnected = await waitUntil(timeoutMs: 1_300) { box.sockets.count >= 2 }
        XCTAssertTrue(reconnected)
        guard let second = box.socket else {
            XCTFail("expected replacement socket")
            return
        }
        XCTAssertFalse(first === second)
        XCTAssertFalse(first.isOpen)

        let replacementReady = await waitUntil(timeoutMs: 250) {
            let frames = second.parsedSent()
            return frames.contains {
                ($0["type"] as? String) == "auth"
                    && ($0["token"] as? String) == "access-token"
            } && frames.contains {
                ($0["type"] as? String) == "subscribe"
                    && ($0["table"] as? String) == "todos"
                    && ($0["id"] as? String) == "7"
            }
        }
        XCTAssertTrue(replacementReady)
        let resynced = await waitUntil(timeoutMs: 250) {
            events.snapshot().filter { $0.op == "RESYNC" }.count == 1
        }
        XCTAssertTrue(resynced)
        XCTAssertEqual(
            http.snapshotCalls().filter { $0.url.contains("/api/todos/7") }.count,
            1
        )

        lateMessage?(#"{"type":"change","table":"todos","op":"UPDATE","id":"7","ts":1}"#)
        lateClose?()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(box.socket === second)
        XCTAssertFalse(events.snapshot().contains { $0.op == "UPDATE" })

        unsub()
        c.closeRealtime()
    }

    func testMismatchedPongDoesNotSatisfyHeartbeat() async throws {
        let box = MockWebSocketBox()
        let ordinal = LockedValue(0)
        let factory: WebSocketFactory = {
            let ws = MockWebSocket()
            let number = ordinal.withValue {
                $0 += 1
                return $0
            }
            if number == 1 {
                ws.onSend = { [weak ws] text in
                    guard let frame = parseRealtimeFrame(text),
                          (frame["type"] as? String) == "ping"
                    else { return }
                    ws?.simulateMessage(#"{"type":"pong","requestId":"hb_stale"}"#)
                }
            } else {
                echoHeartbeatPongs(on: ws)
            }
            box.note(ws)
            return ws
        }
        let c = createClient(
            url: URL(string: "http://example.test")!,
            webSocketFactory: factory,
            realtimeHeartbeat: RealtimeHeartbeatOptions(
                intervalMs: 15,
                responseTimeoutMs: 25
            )
        )
        let unsub = c.from("todos").subscribe { _ in }

        let reconnected = await waitUntil(timeoutMs: 1_300) { box.sockets.count >= 2 }
        XCTAssertTrue(reconnected)
        XCTAssertFalse(box.sockets[0] === box.socket)

        unsub()
        c.closeRealtime()
    }

    func testFinalUnsubscribeAndCloseRealtimeStopHeartbeatTimers() async throws {
        let box = MockWebSocketBox()
        let factory: WebSocketFactory = {
            let ws = MockWebSocket()
            echoHeartbeatPongs(on: ws)
            box.note(ws)
            return ws
        }
        let c = createClient(
            url: URL(string: "http://example.test")!,
            webSocketFactory: factory,
            realtimeHeartbeat: RealtimeHeartbeatOptions(
                intervalMs: 20,
                responseTimeoutMs: 35
            )
        )
        let firstUnsub = c.from("todos").subscribe { _ in }
        let firstPing = await waitUntil(timeoutMs: 200) { pingCount(box.socket) >= 1 }
        XCTAssertTrue(firstPing)
        firstUnsub()
        let afterUnsubscribe = pingCount(box.socket)
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertEqual(pingCount(box.socket), afterUnsubscribe)

        let secondUnsub = c.from("todos").subscribe { _ in }
        let restarted = await waitUntil(timeoutMs: 200) {
            pingCount(box.socket) > afterUnsubscribe
        }
        XCTAssertTrue(restarted)
        c.closeRealtime()
        let afterClose = pingCount(box.socket)
        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertEqual(pingCount(box.socket), afterClose)
        secondUnsub()
    }

    func testTokenRotationsDoNotMultiplyHeartbeatTimers() async throws {
        let box = MockWebSocketBox()
        let factory: WebSocketFactory = {
            let ws = MockWebSocket()
            echoHeartbeatPongs(on: ws)
            box.note(ws)
            return ws
        }
        let c = createClient(
            url: URL(string: "http://example.test")!,
            token: "token-0",
            webSocketFactory: factory,
            realtimeHeartbeat: RealtimeHeartbeatOptions(
                intervalMs: 25,
                responseTimeoutMs: 40
            )
        )
        let unsub = c.from("todos").subscribe { _ in }
        let firstPing = await waitUntil(timeoutMs: 200) { pingCount(box.socket) >= 1 }
        XCTAssertTrue(firstPing)
        box.socket?.clearSent()

        for index in 1...8 {
            c.setToken("token-\(index)")
        }
        try await Task.sleep(nanoseconds: 115_000_000)

        let pingsAfterRotations = pingCount(box.socket)
        XCTAssertGreaterThanOrEqual(pingsAfterRotations, 2)
        XCTAssertLessThanOrEqual(pingsAfterRotations, 5)
        XCTAssertEqual(box.sockets.count, 1)
        unsub()
        c.closeRealtime()
    }

    func testAuthErrorThenTokenRefreshRestoresSubscription() async throws {
        let box = MockWebSocketBox()
        let c = createClient(
            url: URL(string: "http://example.test")!,
            token: "expired-token",
            webSocketFactory: box.factory()
        )
        let controls = LockedValue<[ControlEvent]>([])
        let off = c.onControl { event in
            controls.withValue { $0.append(event) }
        }
        let unsub = c.from("todos").subscribe(rowId: "9") { _ in }
        let opened = await waitUntil(timeoutMs: 150) { box.socket?.isOpen == true }
        XCTAssertTrue(opened)

        box.socket?.simulateMessage(
            #"{"type":"error","code":"AUTH_ERROR","table":"todos","message":"invalid or expired token"}"#
        )
        let surfaced = await waitUntil(timeoutMs: 100) {
            controls.snapshot().contains { $0.code == "AUTH_ERROR" }
        }
        XCTAssertTrue(surfaced)

        box.socket?.clearSent()
        c.setToken("fresh-token")
        let restored = await waitUntil(timeoutMs: 150) {
            let frames = box.socket?.parsedSent() ?? []
            return frames.contains {
                ($0["type"] as? String) == "auth"
                    && ($0["token"] as? String) == "fresh-token"
            } && frames.contains {
                ($0["type"] as? String) == "subscribe"
                    && ($0["token"] as? String) == "fresh-token"
                    && ($0["table"] as? String) == "todos"
                    && ($0["id"] as? String) == "9"
            }
        }
        XCTAssertTrue(restored)

        off()
        unsub()
        c.closeRealtime()
    }

    func testInjectedWebSocketConstructedOnSubscribe() async throws {
        let box = MockWebSocketBox()
        let c = createClient(
            url: URL(string: "http://localhost:3000")!,
            webSocketFactory: box.factory()
        )
        XCTAssertNil(box.socket)
        let unsub = c.from("todos").subscribe { _ in }
        // Allow connect/open
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(box.socket)
        XCTAssertEqual(box.socket?.connectCount, 1)
        unsub()
        c.closeRealtime()
    }

    func testResumeRealtimeReplacesStaleSocketAndKeepsSubscriptions() async throws {
        let http = MockHTTP()
        http.handler = { _, url, _, _ in
            if url.contains("/api/todos/7") {
                return (jsonData(["data": ["id": 7, "title": "foreground"]]), 200)
            }
            return (Data("nope".utf8), 404)
        }
        let box = MockWebSocketBox()
        let events = LockedValue<[ChangeEvent]>([])
        let c = createClient(
            url: URL(string: "http://example.test")!,
            token: "access",
            http: http,
            webSocketFactory: box.factory()
        )
        let unsub = c.from("todos").subscribe(rowId: "7") { event in
            events.withValue { $0.append(event) }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let first = box.socket

        c.resumeRealtime()
        try await Task.sleep(nanoseconds: 100_000_000)

        let second = box.socket
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertFalse(first === second)
        XCTAssertEqual(first?.isOpen, false)
        let frames = second?.parsedSent() ?? []
        XCTAssertTrue(frames.contains {
            ($0["type"] as? String) == "subscribe"
                && ($0["table"] as? String) == "todos"
                && ($0["id"] as? String) == "7"
        })
        XCTAssertTrue(events.snapshot().contains {
            $0.op == "RESYNC" && $0.id == "7" && $0.data?["title"]?.stringValue == "foreground"
        })

        unsub()
        c.closeRealtime()
    }

    func testControlErrorFramesSurfaceWithCode() async throws {
        let box = MockWebSocketBox()
        let c = createClient(
            url: URL(string: "http://localhost:3000")!,
            webSocketFactory: box.factory()
        )
        let controls = LockedValue<[ControlEvent]>([])
        let off = c.onControl { event in controls.withValue { $0.append(event) } }
        let unsub = c.from("todos").subscribe { _ in }
        try await Task.sleep(nanoseconds: 50_000_000)
        box.socket?.simulateMessage(
            #"{"type":"error","code":"AUTH_ERROR","message":"invalid or expired token"}"#
        )
        box.socket?.simulateMessage(
            #"{"type":"error","code":"SUBSCRIBE_ERROR","table":"todos","message":"subscribe forbidden"}"#
        )
        try await Task.sleep(nanoseconds: 20_000_000)
        let controlSnapshot = controls.snapshot()
        XCTAssertTrue(controlSnapshot.contains { $0.type == "error" && $0.code == "AUTH_ERROR" })
        XCTAssertTrue(controlSnapshot.contains { $0.type == "error" && $0.code == "SUBSCRIBE_ERROR" })
        off()
        unsub()
        c.closeRealtime()
    }

    func testSetTokenReauthsAndResubscribes() async throws {
        let box = MockWebSocketBox()
        let c = createClient(
            url: URL(string: "http://localhost:3000")!,
            token: "old-token",
            webSocketFactory: box.factory()
        )
        let unsub = c.from("todos").subscribe(rowId: "1") { _ in }
        try await Task.sleep(nanoseconds: 50_000_000)
        box.socket?.clearSent()
        c.setToken("new-token")
        try await Task.sleep(nanoseconds: 20_000_000)
        let frames = box.socket?.parsedSent() ?? []
        XCTAssertTrue(
            frames.contains { ($0["type"] as? String) == "auth" && ($0["token"] as? String) == "new-token" },
            "\(frames)"
        )
        XCTAssertTrue(
            frames.contains { ($0["type"] as? String) == "subscribe" && ($0["token"] as? String) == "new-token" },
            "\(frames)"
        )
        unsub()
        c.closeRealtime()
    }

    func testRowUnsubSendsId() async throws {
        let box = MockWebSocketBox()
        let c = createClient(
            url: URL(string: "http://localhost:3000")!,
            webSocketFactory: box.factory()
        )
        let u1 = c.from("todos").subscribe(rowId: "1") { _ in }
        let u2 = c.from("todos").subscribe(rowId: "2") { _ in }
        try await Task.sleep(nanoseconds: 40_000_000)
        u1()
        try await Task.sleep(nanoseconds: 20_000_000)
        let unsubs = (box.socket?.parsedSent() ?? []).filter { ($0["type"] as? String) == "unsubscribe" }
        XCTAssertTrue(unsubs.contains { ($0["id"] as? String) == "1" }, "\(unsubs)")
        u2()
        c.closeRealtime()
    }

    func testSubscribeWithHashInRowId() async throws {
        let box = MockWebSocketBox()
        let c = createClient(
            url: URL(string: "http://localhost:3000")!,
            token: "tok1",
            webSocketFactory: box.factory()
        )
        let rowId = "prefix#with#hashes"
        let unsub = c.from("items").subscribe(rowId: rowId) { _ in }
        try await Task.sleep(nanoseconds: 50_000_000)
        let subs = (box.socket?.parsedSent() ?? []).filter { ($0["type"] as? String) == "subscribe" }
        XCTAssertTrue(
            subs.contains { ($0["id"] as? String) == rowId && ($0["table"] as? String) == "items" },
            "\(subs)"
        )
        unsub()
        c.closeRealtime()
    }

    func testRefreshApplyTokensSendsAuthAndResubscribe() async throws {
        let http = MockHTTP()
        http.handler = { _, url, _, _ in
            if url.hasSuffix("/auth/refresh") {
                return (
                    jsonData([
                        "data": [
                            "access_token": "rotated-access",
                            "refresh_token": "rotated-refresh",
                            "token_type": "Bearer",
                            "expires_in": 900,
                        ],
                    ]),
                    200
                )
            }
            return (Data("nope".utf8), 500)
        }
        let box = MockWebSocketBox()
        let c = createClient(
            url: URL(string: "http://example.test")!,
            token: "old-access",
            refreshToken: "r1",
            http: http,
            webSocketFactory: box.factory()
        )
        // Start with open socket: force OPEN immediately for send after refresh.
        let unsub = c.from("todos").subscribe(rowId: "42") { _ in }
        try await Task.sleep(nanoseconds: 50_000_000)
        // Ensure socket is open for reauth path
        if box.socket?.isOpen != true {
            box.socket?.simulateOpen()
        }
        box.socket?.clearSent()
        _ = try await c.refresh()
        XCTAssertEqual(c.accessToken, "rotated-access")
        try await Task.sleep(nanoseconds: 30_000_000)
        let frames = box.socket?.parsedSent() ?? []
        XCTAssertTrue(
            frames.contains { ($0["type"] as? String) == "auth" && ($0["token"] as? String) == "rotated-access" },
            "\(frames)"
        )
        XCTAssertTrue(
            frames.contains {
                ($0["type"] as? String) == "subscribe"
                    && ($0["token"] as? String) == "rotated-access"
                    && ($0["table"] as? String) == "todos"
                    && ($0["id"] as? String) == "42"
            },
            "\(frames)"
        )
        unsub()
        c.closeRealtime()
    }

    func testReconnectResyncDeliversResyncEvents() async throws {
        let http = MockHTTP()
        http.handler = { _, url, _, _ in
            if url.contains("/api/todos/7") {
                return (jsonData(["data": ["id": 7, "title": "after-outage"]]), 200)
            }
            return (Data("nope".utf8), 404)
        }
        let box = MockWebSocketBox()
        let c = createClient(
            url: URL(string: "http://example.test")!,
            token: "t",
            http: http,
            webSocketFactory: box.factory()
        )
        let events = LockedValue<[ChangeEvent]>([])
        let unsub = c.from("todos").subscribe(rowId: "7") { event in
            events.withValue { $0.append(event) }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(events.snapshot().filter { $0.op == "RESYNC" }.count, 0)

        // Drop + reconnect
        box.socket?.simulateClose()
        // Wait for reconnect timer (min ~50ms, jitter up to 1s first attempt)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        try await Task.sleep(nanoseconds: 100_000_000)

        let eventSnapshot = events.snapshot()
        let resyncs = eventSnapshot.filter { $0.op == "RESYNC" }
        XCTAssertGreaterThanOrEqual(resyncs.count, 1, "events=\(eventSnapshot.map { $0.op })")
        if let first = resyncs.first {
            XCTAssertEqual(first.id, "7")
            XCTAssertEqual(first.data?["title"]?.stringValue, "after-outage")
        }
        unsub()
        c.closeRealtime()
    }

    func testSubscribeReadyAwaitsSubscribedAck() async throws {
        let box = MockWebSocketBox()
        let factory: WebSocketFactory = {
            let ws = MockWebSocket()
            ws.onSend = { [weak ws] text in
                guard let data = text.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["type"] as? String) == "subscribe",
                      let rid = obj["requestId"] as? String
                else { return }
                let ack: [String: Any] = [
                    "type": "subscribed",
                    "requestId": rid,
                    "table": "todos",
                    "channel": "todos",
                ]
                if let d = try? JSONSerialization.data(withJSONObject: ack),
                   let s = String(data: d, encoding: .utf8)
                {
                    // Async so pending-ack registration completes first.
                    DispatchQueue.global().async {
                        ws?.simulateMessage(s)
                    }
                }
            }
            box.note(ws)
            return ws
        }
        let c = createClient(
            url: URL(string: "http://example.test")!,
            webSocketFactory: factory
        )
        let unsub = try await c.from("todos").subscribeReady { _ in }
        unsub()
        c.closeRealtime()
    }

    func testSubscribeReadyTimeoutCleansUp() async throws {
        let box = MockWebSocketBox()
        let c = createClient(
            url: URL(string: "http://example.test")!,
            webSocketFactory: box.factory()
        )
        do {
            _ = try await c.from("todos").subscribeReady(timeoutMs: 80) { _ in }
            XCTFail("expected timeout")
        } catch let e as LoomupError {
            XCTAssertTrue(
                e.message.contains("timeout") || e.code == "subscribe_timeout",
                e.message
            )
        }
        c.closeRealtime()
    }

    func testSubscribeReadyRejectsOnErrorFrame() async throws {
        let box = MockWebSocketBox()
        let factory: WebSocketFactory = {
            let ws = MockWebSocket()
            ws.onSend = { [weak ws] text in
                guard let data = text.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["type"] as? String) == "subscribe",
                      let rid = obj["requestId"] as? String
                else { return }
                let err: [String: Any] = [
                    "type": "error",
                    "code": "SUBSCRIBE_ERROR",
                    "requestId": rid,
                    "message": "table not exposed or realtime disabled",
                ]
                if let d = try? JSONSerialization.data(withJSONObject: err),
                   let s = String(data: d, encoding: .utf8)
                {
                    DispatchQueue.global().async {
                        ws?.simulateMessage(s)
                    }
                }
            }
            box.note(ws)
            return ws
        }
        let c = createClient(
            url: URL(string: "http://example.test")!,
            webSocketFactory: factory
        )
        do {
            _ = try await c.from("todos").subscribeReady(timeoutMs: 2000) { _ in }
            XCTFail("expected error")
        } catch let e as LoomupError {
            XCTAssertTrue(
                e.message.contains("table not exposed")
                    || e.code == "SUBSCRIBE_ERROR"
                    || e.message.contains("subscribe"),
                e.message
            )
        }
        c.closeRealtime()
    }

    func testChangeEventFanout() async throws {
        let box = MockWebSocketBox()
        let c = createClient(
            url: URL(string: "http://example.test")!,
            webSocketFactory: box.factory()
        )
        let tableEvents = LockedValue<[ChangeEvent]>([])
        let rowEvents = LockedValue<[ChangeEvent]>([])
        let u1 = c.from("todos").subscribe { event in
            tableEvents.withValue { $0.append(event) }
        }
        let u2 = c.from("todos").subscribe(rowId: "9") { event in
            rowEvents.withValue { $0.append(event) }
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        box.socket?.simulateMessage(
            #"{"type":"change","table":"todos","op":"INSERT","id":"9","data":{"id":9,"title":"x"},"ts":100}"#
        )
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(tableEvents.snapshot().count, 1)
        XCTAssertEqual(rowEvents.snapshot().count, 1)
        XCTAssertEqual(tableEvents.snapshot().first?.op, "INSERT")
        u1()
        u2()
        c.closeRealtime()
    }
}

private func parseRealtimeFrame(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func echoHeartbeatPongs(on socket: MockWebSocket) {
    socket.onSend = { [weak socket] text in
        guard let frame = parseRealtimeFrame(text),
              (frame["type"] as? String) == "ping",
              let requestId = frame["requestId"] as? String,
              let data = try? JSONSerialization.data(withJSONObject: [
                  "type": "pong",
                  "requestId": requestId,
                  "serverTs": 1,
              ]),
              let pong = String(data: data, encoding: .utf8)
        else { return }
        socket?.simulateMessage(pong)
    }
}

private func pingCount(_ socket: MockWebSocket?) -> Int {
    socket?.parsedSent().filter { ($0["type"] as? String) == "ping" }.count ?? 0
}

private func waitUntil(
    timeoutMs: Int,
    condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}
