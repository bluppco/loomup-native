package com.loomup.client

import kotlin.test.Test
import kotlin.test.assertEquals

class RealtimeUrlTest {
    @Test
    fun realtimeWebSocketUrlPreservesBasePath() {
        val cases = listOf(
            "https://tryloomup.com/p/project-id" to "wss://tryloomup.com/p/project-id/realtime",
            "http://localhost:3000" to "ws://localhost:3000/realtime",
            "https://tryloomup.com/p/project-id/" to "wss://tryloomup.com/p/project-id/realtime",
        )

        cases.forEach { (base, expected) ->
            assertEquals(expected, realtimeWebSocketUrl(base))
        }
    }
}
