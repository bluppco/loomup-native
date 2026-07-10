package com.litebase.client

/**
 * Litebase — Kotlin client for Litebase Realtime.
 *
 * Mirrors the TypeScript `@litebase/client` and Swift `Litebase` SDKs:
 *
 * ```kotlin
 * import com.litebase.client.createClient
 *
 * val client = createClient(url = "http://127.0.0.1:3000")
 * val tokens = client.auth.signUp(email = "a@b.com", password = "secret12")
 * val list = client.from("todos").select(
 *     where = mapOf("completed" to WhereValue.Bool(false)),
 *     limit = 20,
 * )
 * val unsub = client.from("todos").subscribeReady { event ->
 *     println("${event.op} ${event.data}")
 * }
 * unsub()
 * client.closeRealtime()
 * ```
 */

data class LitebaseClientOptions(
    val url: String,
    val token: String? = null,
    val refreshToken: String? = null,
    val http: HttpTransport = OkHttpHttpTransport(),
    val webSocketFactory: WebSocketFactory? = null,
)

/** Create a Litebase client (TypeScript `createClient` equivalent). */
fun createClient(
    url: String,
    token: String? = null,
    refreshToken: String? = null,
    http: HttpTransport = OkHttpHttpTransport(),
    webSocketFactory: WebSocketFactory? = null,
): LitebaseClient {
    return LitebaseClient(
        LitebaseClientOptions(
            url = url,
            token = token,
            refreshToken = refreshToken,
            http = http,
            webSocketFactory = webSocketFactory,
        ),
    )
}
