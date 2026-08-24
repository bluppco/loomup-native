import CryptoKit
import Foundation

/// Exact request material an app-integrity provider must prove. `body` is the
/// same byte sequence the client sends on the wire.
public struct AppIntegrityRequest: Sendable {
    public let method: String
    public let pathAndQuery: String
    public let body: Data
    public let bodySHA256: String
    public let authorizationToken: String?

    public init(
        method: String,
        pathAndQuery: String,
        body: Data,
        authorizationToken: String?
    ) {
        self.method = method.uppercased()
        self.pathAndQuery = pathAndQuery
        self.body = body
        self.bodySHA256 = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        self.authorizationToken = authorizationToken
    }
}

/// Produces a short-lived, single-use grant for an exact mutation request.
public protocol AppIntegrityProvider: Sendable {
    func prepareGrant(for request: AppIntegrityRequest) async throws -> String
}

/// Secure persistence boundary. Mobile factories persist only refresh tokens;
/// access tokens remain in process memory.
public protocol RefreshTokenStore: Sendable {
    func loadRefreshToken() throws -> String?
    func saveRefreshToken(_ token: String?) throws
}
