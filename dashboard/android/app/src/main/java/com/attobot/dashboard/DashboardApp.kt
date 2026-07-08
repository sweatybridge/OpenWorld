package com.attobot.dashboard

import android.app.Application
import com.attobot.dashboard.core.ApiProvider
import com.attobot.dashboard.core.Credentials

/**
 * Application entry point. Owns the [Credentials] + [ApiProvider] singletons —
 * they are configured once here with the application context so every screen can
 * read the live base URL / token without re-initialising storage.
 *
 * Mirrors the RN client, where `loadCredentials()` runs once at startup and the
 * synchronous apiFetch reads module-level state.
 */
class DashboardApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Credentials.init(this)
        ApiProvider.init()
    }
}
