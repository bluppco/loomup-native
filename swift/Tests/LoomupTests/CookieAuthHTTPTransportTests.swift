import Foundation
import XCTest
@testable import Loomup

final class CookieAuthHTTPTransportTests: XCTestCase {
    func testResponseRotationWinsOverStaleCookieJar() throws {
        let response = Data(#"{"data":{"expires_in":900,"token_type":"Bearer"}}"#.utf8)
        let url = try XCTUnwrap(URL(string: "https://tryloomup.com/p/project/auth/refresh"))
        let fresh = HTTPCookie.cookies(withResponseHeaderFields: [
            "Set-Cookie": "loomup_access=access-2; Path=/, loomup_refresh=refresh-2; Path=/",
        ], for: url)
        let stale = HTTPCookie.cookies(withResponseHeaderFields: [
            "Set-Cookie": "loomup_access=access-1; Path=/, loomup_refresh=refresh-1; Path=/",
        ], for: url)

        let completed = CookieAuthHTTPTransport.addingMissingTokens(
            to: response,
            responseCookies: fresh,
            storedCookies: stale
        )
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: completed) as? [String: Any]
        )
        let payload = try XCTUnwrap(envelope["data"] as? [String: Any])
        XCTAssertEqual(payload["access_token"] as? String, "access-2")
        XCTAssertEqual(payload["refresh_token"] as? String, "refresh-2")
    }

    func testJsonTokenWinsAndHyphenCookieNamesAreSupported() throws {
        let response = Data(
            #"{"data":{"access_token":"json-access","expires_in":900,"token_type":"Bearer"}}"#.utf8
        )
        let url = try XCTUnwrap(URL(string: "https://tryloomup.com/p/project/auth/login"))
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: [
            "Set-Cookie": "loomup-access=cookie-access; Path=/, loomup-refresh=refresh-cookie; Path=/",
        ], for: url)

        let completed = CookieAuthHTTPTransport.addingMissingTokens(
            to: response,
            responseCookies: cookies
        )
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: completed) as? [String: Any]
        )
        let payload = try XCTUnwrap(envelope["data"] as? [String: Any])
        XCTAssertEqual(payload["access_token"] as? String, "json-access")
        XCTAssertEqual(payload["refresh_token"] as? String, "refresh-cookie")
    }
}
