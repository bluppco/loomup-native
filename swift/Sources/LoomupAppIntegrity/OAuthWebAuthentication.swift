import AuthenticationServices
import Foundation
import Loomup

@available(iOS 16.0, macOS 12.0, *)
@MainActor
private final class OAuthWebAuthenticationRunner {
    private var session: ASWebAuthenticationSession?

    func run(
        authorizationURL: URL,
        callbackScheme: String,
        presentationContextProvider: ASWebAuthenticationPresentationContextProviding
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                self?.session = nil
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: LoomupError(
                        "OAuth session returned no callback URL",
                        code: "oauth_callback_missing"
                    ))
                }
            }
            session.presentationContextProvider = presentationContextProvider
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                self.session = nil
                continuation.resume(throwing: LoomupError(
                    "OAuth session could not start",
                    code: "oauth_session_failed"
                ))
            }
        }
    }
}

/// Starts a system authentication session and exchanges the one-time Loomup
/// handoff code. The verifier exists only for the duration of this call.
@available(iOS 16.0, macOS 12.0, *)
@MainActor
public func signInWithOAuth(
    client: LoomupClient,
    provider: OAuthProvider,
    redirectTo: URL,
    presentationContextProvider: ASWebAuthenticationPresentationContextProviding
) async throws -> AuthTokens {
    guard let scheme = redirectTo.scheme, !scheme.isEmpty else {
        throw LoomupError("OAuth redirect URL must include a scheme", code: "invalid_redirect")
    }
    let authorization = try await client.auth.authorizeOAuth(
        provider: provider,
        redirectTo: redirectTo.absoluteString
    )
    guard let authorizationURL = URL(string: authorization.authorizationURL) else {
        throw LoomupError("OAuth authorization URL is invalid", code: "invalid_response")
    }
    let callback = try await OAuthWebAuthenticationRunner().run(
        authorizationURL: authorizationURL,
        callbackScheme: scheme,
        presentationContextProvider: presentationContextProvider
    )
    guard
        callback.scheme?.lowercased() == redirectTo.scheme?.lowercased(),
        callback.user == redirectTo.user,
        callback.password == redirectTo.password,
        callback.host?.lowercased() == redirectTo.host?.lowercased(),
        callback.port == redirectTo.port,
        callback.path == redirectTo.path
    else {
        throw LoomupError(
            "OAuth callback does not match redirectTo",
            code: "oauth_callback_mismatch"
        )
    }
    guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
        throw LoomupError("OAuth callback URL is invalid", code: "invalid_response")
    }
    if let providerError = components.queryItems?.first(where: { $0.name == "error" })?.value {
        throw LoomupError("OAuth sign-in failed: \(providerError)", code: providerError)
    }
    guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
        throw LoomupError("OAuth callback did not include a code", code: "oauth_callback_missing")
    }
    return try await client.auth.exchangeOAuthCode(
        code: code,
        codeVerifier: authorization.codeVerifier
    )
}
