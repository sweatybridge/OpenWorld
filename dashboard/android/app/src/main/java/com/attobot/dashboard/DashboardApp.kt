package com.attobot.dashboard

import android.app.Application
import coil.ImageLoader
import coil.ImageLoaderFactory
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
class DashboardApp : Application(), ImageLoaderFactory {
    override fun onCreate() {
        super.onCreate()
        Credentials.init(this)
        ApiProvider.init()
    }

    /**
     * Coil singleton: built on [ApiProvider]'s OkHttp client so image requests
     * (e.g. the Media page's `/api/media/{id}/thumbnail`) inherit the bearer-
     * token interceptor and reach the dashboard the same way JSON calls do.
     */
    override fun newImageLoader(): ImageLoader =
        ImageLoader.Builder(this)
            .okHttpClient(ApiProvider.okhttp())
            .crossfade(true)
            .build()
}
