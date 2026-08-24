package com.loomup.client.android

import android.content.Context
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager
import com.loomup.client.AppIntegrityProvider
import com.loomup.client.AppIntegrityRequest
import com.loomup.client.HttpRequest
import com.loomup.client.HttpTransport
import com.loomup.client.OkHttpHttpTransport
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class PlayIntegrityProvider(
    context: Context,
    private val baseUrl: String,
    private val appId: String,
    private val cloudProjectNumber: Long,
    private val http: HttpTransport = OkHttpHttpTransport(),
) : AppIntegrityProvider {
    private val manager = IntegrityManagerFactory.createStandard(context.applicationContext)
    private val providerLock = Mutex()
    private var tokenProvider: StandardIntegrityManager.StandardIntegrityTokenProvider? = null
    private val json = Json { ignoreUnknownKeys = true }

    /** Warm Play's standard token provider before a latency-sensitive action. */
    suspend fun prepare() {
        providerLock.withLock {
            if (tokenProvider == null) {
                tokenProvider = manager.prepareIntegrityToken(
                    StandardIntegrityManager.PrepareIntegrityTokenRequest.builder()
                        .setCloudProjectNumber(cloudProjectNumber)
                        .build(),
                ).awaitResult()
            }
        }
    }

    override suspend fun prepareGrant(request: AppIntegrityRequest): String {
        val challenge = post<ChallengeBody, ChallengeEnvelope>(
            "/app-integrity/v1/challenge",
            ChallengeBody(
                appId = appId,
                method = request.method,
                pathAndQuery = request.pathAndQuery,
                bodySha256 = request.bodySha256,
            ),
            request.authorizationToken,
        )
        prepare()
        val integrityToken = requestToken(challenge.data.requestHash)
        val verified = post<VerifyBody, VerifyEnvelope>(
            "/app-integrity/v1/verify",
            VerifyBody(
                challengeId = challenge.data.challengeId,
                appId = appId,
                proof = PlayProof(integrityToken),
            ),
            request.authorizationToken,
        )
        return verified.data.grant
    }

    private suspend fun requestToken(requestHash: String): String {
        fun request(provider: StandardIntegrityManager.StandardIntegrityTokenProvider) =
            provider.request(
                StandardIntegrityManager.StandardIntegrityTokenRequest.builder()
                    .setRequestHash(requestHash)
                    .build(),
            )
        return try {
            request(checkNotNull(tokenProvider)).awaitResult().token()
        } catch (error: Exception) {
            // Standard providers expire; re-warm once and retry.
            providerLock.withLock { tokenProvider = null }
            prepare()
            request(checkNotNull(tokenProvider)).awaitResult().token()
        }
    }

    private suspend inline fun <reified Body : Any, reified Response : Any> post(
        path: String,
        body: Body,
        token: String?,
    ): Response {
        val headers = linkedMapOf(
            "Accept" to "application/json",
            "Content-Type" to "application/json",
        )
        if (token != null) headers["Authorization"] = "Bearer $token"
        val response = http.execute(
            HttpRequest(
                method = "POST",
                url = baseUrl.trimEnd('/') + path,
                headers = headers,
                body = json.encodeToString(body).toByteArray(),
            ),
        )
        check(response.status in 200..299) {
            "Loomup app integrity HTTP ${response.status}: ${String(response.body)}"
        }
        return json.decodeFromString(String(response.body))
    }
}

@Serializable
private data class ChallengeBody(
    @SerialName("app_id") val appId: String,
    val platform: String = "android",
    val method: String,
    @SerialName("path_and_query") val pathAndQuery: String,
    @SerialName("body_sha256") val bodySha256: String,
)

@Serializable
private data class ChallengeEnvelope(val data: ChallengeData)

@Serializable
private data class ChallengeData(
    @SerialName("challenge_id") val challengeId: String,
    val nonce: String,
    @SerialName("request_hash") val requestHash: String,
)

@Serializable
private data class PlayProof(@SerialName("integrity_token") val integrityToken: String)

@Serializable
private data class VerifyBody(
    @SerialName("challenge_id") val challengeId: String,
    @SerialName("app_id") val appId: String,
    val platform: String = "android",
    @SerialName("proof_kind") val proofKind: String = "google_play_integrity",
    val proof: PlayProof,
)

@Serializable
private data class VerifyEnvelope(val data: VerifyData)

@Serializable
private data class VerifyData(val grant: String)
