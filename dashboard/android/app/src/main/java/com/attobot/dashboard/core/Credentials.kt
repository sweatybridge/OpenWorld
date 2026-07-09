package com.attobot.dashboard.core

import android.content.Context
import android.content.SharedPreferences
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

/**
 * Credential persistence — the Android analogue of dashboard/mobile/src/lib/store.ts.
 *
 * The web app stores a bearer token in localStorage and hits a relative `/api`.
 * A phone can't reach the dev box's 127.0.0.1, so the base URL is configurable
 * (Preferences DataStore — not secret) and the bearer token lives in
 * EncryptedSharedPreferences (the keystore-backed equivalent of expo-secure-store).
 *
 * Both values are mirrored into in-memory caches at [load] time so the OkHttp
 * auth interceptor can read the token synchronously on the network thread and
 * the gate can branch on [hasBaseUrl] without suspending.
 */
object Credentials {

    private val Context.settingsDataStore: DataStore<Preferences> by preferencesDataStore(name = "settings")
    private val BASE_URL_KEY = stringPreferencesKey("base_url")

    private const val SECRES_FILE = "secrets.xml"
    private const val TOKEN_KEY = "token"
    private const val MASTER_ALIAS = "attobot_master_key"

    private lateinit var appContext: Context

    @Volatile private var baseUrlCache: String = ""
    @Volatile private var tokenCache: String = ""
    @Volatile private var loaded: Boolean = false

    private val _baseUrlFlow = MutableStateFlow("")
    /** The current server base URL, for reactive consumers (e.g. ApiProvider). */
    val baseUrlFlow: StateFlow<String> = _baseUrlFlow.asStateFlow()

    /** Wire once with the application context (see [com.attobot.dashboard.DashboardApp]). */
    fun init(context: Context) {
        appContext = context.applicationContext
    }

    /** Current base URL (no trailing slash), mirrored in memory. */
    val currentBaseUrl: String get() = baseUrlCache

    /** Current bearer token (mirrored in memory) — safe to call from any thread. */
    fun currentToken(): String = tokenCache

    fun hasBaseUrl(): Boolean = baseUrlCache.isNotEmpty()

    /** Load persisted credentials into the in-memory caches. Idempotent. */
    suspend fun load() {
        val base = appContext.settingsDataStore.data
            .map { it[BASE_URL_KEY] ?: "" }
            .first()
        baseUrlCache = base
        _baseUrlFlow.value = base
        tokenCache = readTokenFromDisk()
        loaded = true
    }

    /** Persist the base URL + token and refresh the in-memory caches. */
    suspend fun save(rawBase: String, token: String) {
        val base = normalize(rawBase)
        baseUrlCache = base
        _baseUrlFlow.value = base
        tokenCache = token
        appContext.settingsDataStore.edit { it[BASE_URL_KEY] = base }
        writeToken(token)
    }

    /** Wipe the token (base URL retained) and refresh the cache. */
    suspend fun clearToken() {
        tokenCache = ""
        writeToken("")
    }

    private fun readTokenFromDisk(): String =
        try {
            secrets()?.getString(TOKEN_KEY, "") ?: ""
        } catch (e: Exception) {
            // EncryptedSharedPreferences can throw on emulators / unlocked issues.
            ""
        }

    private fun writeToken(token: String) {
        try {
            val prefs = secrets() ?: return
            prefs.edit().apply {
                if (token.isNotEmpty()) putString(TOKEN_KEY, token) else remove(TOKEN_KEY)
            }.apply()
        } catch (e: Exception) {
            // Swallow — the in-memory copy is still authoritative for this session.
        }
    }

    private fun secrets(): SharedPreferences? = try {
        val masterKey = MasterKey.Builder(appContext, MASTER_ALIAS)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            appContext,
            SECRES_FILE,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    } catch (e: Exception) {
        null
    }

    /** Trim trailing slashes so `base + "/api/..."` never doubles up. */
    private fun normalize(raw: String): String {
        var b = raw.trim()
        while (b.endsWith('/')) b = b.dropLast(1)
        return b
    }
}
