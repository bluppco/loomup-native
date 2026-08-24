package com.loomup.client

import kotlinx.coroutines.runBlocking
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class AppIntegrityTest {
    @Test
    fun mutationGrantBindsExactBytesAndAuthorization() = runBlocking {
        val requests = CopyOnWriteArrayList<AppIntegrityRequest>()
        val provider = AppIntegrityProvider { request ->
            requests += request
            "grant-${requests.size}"
        }
        val http = MockHttp().apply {
            handler = { _, _, _, _ -> jsonBytes("""{"data":{"id":1}}""") to 200 }
        }
        val client = createClient(
            url = "https://example.test",
            token = "access-token",
            appIntegrityProvider = provider,
            http = http,
        )

        client.from("todos").delete(1)

        assertEquals(1, requests.size)
        assertEquals("DELETE", requests[0].method)
        assertEquals("/api/todos/1", requests[0].pathAndQuery)
        assertEquals("access-token", requests[0].authorizationToken)
        val call = http.snapshotCalls().single()
        assertContentEquals(call.body ?: ByteArray(0), requests[0].body)
        assertEquals("grant-1", call.appGrant)
    }

    @Test
    fun requiredResponseObtainsOneFreshGrantAndRetriesOnce() = runBlocking {
        val grantCount = java.util.concurrent.atomic.AtomicInteger()
        val provider = AppIntegrityProvider { "grant-${grantCount.incrementAndGet()}" }
        val http = MockHttp()
        http.handler = { _, _, _, _ ->
            if (http.snapshotCalls().size == 1) {
                jsonBytes("""{"error":{"code":"app_integrity_required","message":"fresh proof required"}}""") to 403
            } else {
                jsonBytes("""{"data":{"id":1}}""") to 200
            }
        }
        val client = createClient(
            url = "https://example.test",
            appIntegrityProvider = provider,
            http = http,
        )

        client.from("todos").delete(1)

        assertEquals(2, grantCount.get())
        assertEquals(listOf("grant-1", "grant-2"), http.snapshotCalls().map { it.appGrant })
    }


    @Test
    fun grantBindsNormalizedBackendTargetWithoutProxyBasePath() = runBlocking {
        val requests = CopyOnWriteArrayList<AppIntegrityRequest>()
        val provider = AppIntegrityProvider { request ->
            requests += request
            "grant"
        }
        val http = MockHttp().apply {
            handler = { _, _, _, _ -> jsonBytes("""{"data":{"ok":true}}""") to 200 }
        }
        val client = createClient(
            url = "https://example.test/edge",
            appIntegrityProvider = provider,
            http = http,
        )

        client.request("DELETE", "/api/todos?label=hello world")

        assertEquals("/api/todos?label=hello%20world", requests.single().pathAndQuery)
    }
}
