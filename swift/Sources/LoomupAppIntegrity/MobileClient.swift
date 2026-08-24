import Foundation
import Loomup

/// Secure-by-default iOS construction: App Attest for mutations, refresh token
/// in Keychain, and access token only in memory. There is intentionally no
/// service-key parameter.
@available(iOS 16.0, *)
public func createMobileClient(
    url: URL,
    appID: String,
    token: String? = nil,
    http: any HTTPTransport = URLSessionHTTPTransport(),
    webSocketFactory: WebSocketFactory? = nil
) -> LoomupClient {
    let refreshStore = KeychainRefreshTokenStore(account: appID)
    let integrity = AppleAppIntegrityProvider(baseURL: url, appID: appID, http: http)
    return LoomupClient(
        options: LoomupClientOptions(
            url: url,
            token: token,
            appIntegrityProvider: integrity,
            refreshTokenStore: refreshStore,
            http: http,
            webSocketFactory: webSocketFactory
        )
    )
}
