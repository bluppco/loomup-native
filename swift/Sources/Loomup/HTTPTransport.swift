import Foundation

/// Injectable HTTP transport (defaults to `URLSession`).
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func download(for request: URLRequest) async throws -> (URL, URLResponse)
}

public extension HTTPTransport {
    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        throw LoomupError("This transport does not support file downloads", code: "unsupported_transport")
    }
}

public struct URLSessionHTTPTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await session.download(for: request)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// URLSession transport for hosted Loomup projects that return native auth
/// tokens in HttpOnly cookies. Response cookies always win over the shared
/// cookie jar so a rotated refresh token cannot be replaced by its revoked
/// predecessor.
public struct CookieAuthHTTPTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await session.download(for: request)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              let url = request.url,
              (200..<300).contains(httpResponse.statusCode),
              Self.isTokenResponse(url) else {
            return (data, response)
        }

        let responseCookies = Self.responseCookies(httpResponse, for: url)
        let storedCookies = session.configuration.httpCookieStorage?.cookies(for: url) ?? []
        return (
            Self.addingMissingTokens(
                to: data,
                responseCookies: responseCookies,
                storedCookies: storedCookies
            ),
            response
        )
    }

    static func addingMissingTokens(
        to data: Data,
        responseCookies: [HTTPCookie],
        storedCookies: [HTTPCookie] = []
    ) -> Data {
        guard var envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var payload = envelope["data"] as? [String: Any] else {
            return data
        }

        var changed = false
        if payload["access_token"] == nil,
           let accessToken = cookieValue(
               responseCookies: responseCookies,
               storedCookies: storedCookies,
               names: ["loomup_access", "loomup-access"]
           ) {
            payload["access_token"] = accessToken
            changed = true
        }
        if payload["refresh_token"] == nil,
           let refreshToken = cookieValue(
               responseCookies: responseCookies,
               storedCookies: storedCookies,
               names: ["loomup_refresh", "loomup-refresh"]
           ) {
            payload["refresh_token"] = refreshToken
            changed = true
        }

        guard changed else { return data }
        envelope["data"] = payload
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? data
    }

    private static func isTokenResponse(_ url: URL) -> Bool {
        ["/auth/login", "/auth/register", "/auth/refresh", "/auth/oauth/exchange"]
            .contains { url.path.hasSuffix($0) }
    }

    private static func responseCookies(_ response: HTTPURLResponse, for url: URL) -> [HTTPCookie] {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = String(describing: entry.value)
        }
        return HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
    }

    private static func cookieValue(
        responseCookies: [HTTPCookie],
        storedCookies: [HTTPCookie],
        names: Set<String>
    ) -> String? {
        responseCookies.last(where: { names.contains($0.name) && !$0.value.isEmpty })?.value
            ?? storedCookies.last(where: { names.contains($0.name) && !$0.value.isEmpty })?.value
    }
}
