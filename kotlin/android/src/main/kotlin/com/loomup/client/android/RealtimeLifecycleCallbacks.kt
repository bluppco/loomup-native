package com.loomup.client.android

import android.app.Activity
import android.app.Application
import android.os.Bundle
import com.loomup.client.LoomupClient
import java.lang.ref.WeakReference

internal fun Application.observeRealtimeLifecycle(client: LoomupClient) {
    registerActivityLifecycleCallbacks(RealtimeLifecycleCallbacks(client))
}

private class RealtimeLifecycleCallbacks(
    client: LoomupClient,
) : Application.ActivityLifecycleCallbacks {
    private val client = WeakReference(client)
    private var startedActivities = 0
    private var configurationChanges = 0

    override fun onActivityStarted(activity: Activity) {
        if (configurationChanges > 0) {
            configurationChanges -= 1
            return
        }
        val returningToForeground = startedActivities == 0
        startedActivities += 1
        if (returningToForeground) {
            client.get()?.resumeRealtime()
        }
    }

    override fun onActivityStopped(activity: Activity) {
        if (activity.isChangingConfigurations) {
            configurationChanges += 1
        } else {
            startedActivities = maxOf(0, startedActivities - 1)
        }
    }

    override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
    override fun onActivityResumed(activity: Activity) = Unit
    override fun onActivityPaused(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
    override fun onActivityDestroyed(activity: Activity) = Unit
}
