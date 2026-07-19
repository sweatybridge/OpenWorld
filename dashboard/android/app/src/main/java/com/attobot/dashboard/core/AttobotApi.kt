package com.attobot.dashboard.core

import com.attobot.dashboard.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.HttpException
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory
import retrofit2.http.GET
import retrofit2.http.Path
import retrofit2.http.Query
import java.io.IOException
import java.util.concurrent.TimeUnit

/** 401 from the dashboard — the token is missing/wrong. Surfaces the Setup gate. */
class AuthException(message: String = "unauthorized") : Exception(message)

/** Any non-2xx response other than 401, or a network failure reaching the host. */
class ApiException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Retrofit definition for the read-only `/api` endpoints. All nullable query
 * params are omitted by Retrofit when null (so a missing filter isn't sent).
 */
interface AttobotApi {

    @GET("api/overview")
    suspend fun overview(): Overview

    @GET("api/workflows")
    suspend fun workflows(
        @Query("status") status: String? = null,
        @Query("type") type: String? = null,
        @Query("agent") agent: String? = null,
        @Query("q") q: String? = null,
        @Query("limit") limit: Int? = null,
        @Query("offset") offset: Int? = null,
    ): WorkflowList

    @GET("api/workflows/{id}")
    suspend fun workflow(@Path("id") id: String): WorkflowDetail

    @GET("api/trace/{messageId}")
    suspend fun trace(@Path("messageId") messageId: Long): TraceResponse

    @GET("api/agents")
    suspend fun agents(): AgentsResponse

    @GET("api/agents/{id}/messages")
    suspend fun messages(
        @Path("id") id: String,
        @Query("limit") limit: Int? = null,
        @Query("before") before: Long? = null,
    ): MessagesResponse

    @GET("api/memory")
    suspend fun memory(@Query("agent_id") agentId: String? = null): MemoryResponse

    @GET("api/users")
    suspend fun users(): UsersResponse

    @GET("api/config")
    suspend fun config(@Query("agent_id") agentId: String? = null): ConfigResponse
}

/**
 * Owns the [OkHttpClient] (single instance) + a Retrofit client that is rebuilt
 * whenever the configured base URL changes. Exposes suspend wrappers that map
 * 401 → [AuthException] and other failures → [ApiException], mirroring the RN
 * `apiFetch` which throws `AuthError` on 401 and `Error("HTTP …")` otherwise.
 *
 * The OkHttp auth interceptor reads the live token from [Credentials] on every
 * request, so a token saved in Setup is used immediately without rebuilding the
 * client.
 */
object ApiProvider {

    val json: Json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        explicitNulls = false
    }

    private val okhttp: OkHttpClient by lazy { buildClient() }

    @Volatile private var retrofit: Retrofit? = null
    @Volatile private var cachedBase: String = "sentinel"
    private val lock = Any()

    /** No-op marker; the object holds state initialized lazily. Kept for symmetry. */
    fun init() = Unit

    private fun buildClient(): OkHttpClient {
        val builder = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .writeTimeout(20, TimeUnit.SECONDS)
            .addInterceptor { chain ->
                val request = chain.request()
                val token = Credentials.currentToken()
                val built = if (token.isNotEmpty()) {
                    request.newBuilder().header("Authorization", "Bearer $token").build()
                } else {
                    request
                }
                chain.proceed(built)
            }
        if (BuildConfig.DEBUG) {
            builder.addInterceptor(
                HttpLoggingInterceptor().apply { level = HttpLoggingInterceptor.Level.BASIC }
            )
        }
        return builder.build()
    }

    private fun retrofit(): Retrofit {
        val base = Credentials.currentBaseUrl
        return synchronized(lock) {
            val cached = retrofit
            if (base == cachedBase && cached != null) {
                cached
            } else {
                val normalized = when {
                    base.isEmpty() -> "http://localhost/"
                    base.endsWith("/") -> base
                    else -> "$base/"
                }
                val built = Retrofit.Builder()
                    .baseUrl(normalized)
                    .client(okhttp)
                    .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
                    .build()
                cachedBase = base
                retrofit = built
                built
            }
        }
    }

    private fun api(): AttobotApi = retrofit().create(AttobotApi::class.java)

    /** Wraps a Retrofit call: maps 401 → [AuthException], everything else → [ApiException]. */
    private suspend fun <T> req(block: suspend AttobotApi.() -> T): T = try {
        api().block()
    } catch (e: AuthException) {
        throw e
    } catch (e: HttpException) {
        if (e.code() == 401) throw AuthException() else throw ApiException("HTTP ${e.code()}", e)
    } catch (e: IOException) {
        throw ApiException(
            "Cannot reach the dashboard API. Check the server URL and that the host is reachable from this device.",
            e,
        )
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        // Serialization errors etc.
        throw ApiException(e.message ?: "Unknown error", e)
    }

    // ---- Typed suspend entry points (used by the ViewModels) ----

    suspend fun overview(): Overview = req { overview() }

    suspend fun workflows(
        status: String? = null,
        type: String? = null,
        agent: String? = null,
        q: String? = null,
        limit: Int? = null,
        offset: Int? = null,
    ): WorkflowList = req { workflows(status?.ifBlank { null }, type?.ifBlank { null }, agent?.ifBlank { null }, q?.ifBlank { null }, limit, offset) }

    suspend fun workflow(id: String): WorkflowDetail = req { workflow(id) }

    suspend fun trace(messageId: Long): List<TraceRow> = req { trace(messageId) }.rows

    suspend fun agents(): List<AgentRow> = req { agents() }.rows

    suspend fun messages(agentId: String, limit: Int = 50, before: Long? = null): List<MessageRow> =
        req { messages(agentId, limit, before) }.rows

    suspend fun memory(agentId: String? = null): List<MemoryRow> =
        req { memory(agentId?.ifBlank { null }) }.rows

    suspend fun users(): List<UserRow> = req { users() }.rows

    suspend fun config(agentId: String? = null): List<ConfigRow> =
        req { config(agentId?.ifBlank { null }) }.rows
}
