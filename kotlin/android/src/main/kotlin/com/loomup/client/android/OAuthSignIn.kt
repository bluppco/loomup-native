package com.loomup.client.android

import com.loomup.client.AuthTokens
import com.loomup.client.LoomupClient
import com.loomup.client.LoomupError
import com.loomup.client.OAuthProvider
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

/** App-owned Custom Tab/deep-link bridge. Resolves with the callback URI. */
fun interface OAuthSessionLauncher {
    suspend fun open(authorizationUrl: String, redirectTo: String): String
}

suspend fun signInWithOAuth(
    client: LoomupClient,
    provider: OAuthProvider,
    redirectTo: String,
    launcher: OAuthSessionLauncher,
): AuthTokens {
    val authorization = client.auth.authorizeOAuth(provider, redirectTo)
    val expectedCallback = URI(redirectTo)
    val callback = URI(launcher.open(authorization.authorizationUrl, redirectTo))
    val callbackMatchesRedirect =
        callback.scheme.equals(expectedCallback.scheme, ignoreCase = true) &&
            callback.rawUserInfo == expectedCallback.rawUserInfo &&
            callback.host.equals(expectedCallback.host, ignoreCase = true) &&
            callback.port == expectedCallback.port &&
            callback.rawPath == expectedCallback.rawPath
    if (!callbackMatchesRedirect) {
        throw LoomupError(
            "OAuth callback does not match redirectTo",
            code = "oauth_callback_mismatch",
        )
    }
    val parameters = callback.rawQuery
        ?.split("&")
        ?.mapNotNull { entry ->
            val parts = entry.split("=", limit = 2)
            if (parts.isEmpty()) null else {
                val name = URLDecoder.decode(parts[0], StandardCharsets.UTF_8)
                val value = URLDecoder.decode(parts.getOrElse(1) { "" }, StandardCharsets.UTF_8)
                name to value
            }
        }
        ?.toMap()
        .orEmpty()
    parameters["error"]?.let { error ->
        throw LoomupError("OAuth sign-in failed: $error", code = error)
    }
    val code = parameters["code"]
        ?: throw LoomupError("OAuth callback did not include a code", code = "oauth_callback_missing")
    return client.auth.exchangeOAuthCode(code, authorization.codeVerifier)
}
