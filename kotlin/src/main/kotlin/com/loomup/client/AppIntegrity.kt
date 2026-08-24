package com.loomup.client

import java.security.MessageDigest

data class AppIntegrityRequest(
    val method: String,
    val pathAndQuery: String,
    val body: ByteArray,
    val authorizationToken: String?,
) {
    val bodySha256: String = MessageDigest.getInstance("SHA-256")
        .digest(body)
        .joinToString("") { "%02x".format(it) }
}

fun interface AppIntegrityProvider {
    suspend fun prepareGrant(request: AppIntegrityRequest): String
}

/** Persist refresh tokens only. Access tokens remain in process memory. */
interface RefreshTokenStore {
    fun loadRefreshToken(): String?
    fun saveRefreshToken(token: String?)
}
