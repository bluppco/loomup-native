import XCTest
@testable import Loomup

final class RealtimeURLTests: XCTestCase {
    func testRealtimeWebSocketURLPreservesBasePath() {
        let cases = [
            ("https://tryloomup.com/p/project-id", "wss://tryloomup.com/p/project-id/realtime"),
            ("http://localhost:3000", "ws://localhost:3000/realtime"),
            ("https://tryloomup.com/p/project-id/", "wss://tryloomup.com/p/project-id/realtime"),
        ]

        for (base, expected) in cases {
            XCTAssertEqual(
                realtimeWebSocketURL(from: URL(string: base)!).absoluteString,
                expected
            )
        }
    }
}
