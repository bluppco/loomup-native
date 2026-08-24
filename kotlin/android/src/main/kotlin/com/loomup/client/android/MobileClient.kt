package com.loomup.client.android

import android.content.Context
import com.loomup.client.HttpTransport
import com.loomup.client.LoomupClient
import com.loomup.client.LoomupClientOptions
import com.loomup.client.OkHttpHttpTransport
import com.loomup.client.WebSocketFactory

/** Secure mobile construction with no service-key input. */
fun createAndroidClient(
    context: Context,
    url: String,
    appId: String,
    cloudProjectNumber: Long,
    token: String? = null,
    http: HttpTransport = OkHttpHttpTransport(),
    webSocketFactory: WebSocketFactory? = null,
): LoomupClient {
    val refreshStore = AndroidRefreshTokenStore(context, appId)
    val integrity = PlayIntegrityProvider(context, url, appId, cloudProjectNumber, http)
    return LoomupClient(
        LoomupClientOptions(
            url = url,
            token = token,
            appIntegrityProvider = integrity,
            refreshTokenStore = refreshStore,
            http = http,
            webSocketFactory = webSocketFactory,
        ),
    )
}
