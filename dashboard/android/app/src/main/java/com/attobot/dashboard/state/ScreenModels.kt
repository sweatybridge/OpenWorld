package com.attobot.dashboard.state

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.attobot.dashboard.core.AgentRow
import com.attobot.dashboard.core.ApiProvider
import com.attobot.dashboard.core.AuthException
import com.attobot.dashboard.core.BlobRow
import com.attobot.dashboard.core.ConfigRow
import com.attobot.dashboard.core.LifecycleRow
import com.attobot.dashboard.core.MemoryRow
import com.attobot.dashboard.core.Overview
import com.attobot.dashboard.core.UserRow
import com.attobot.dashboard.core.MessageRow
import com.attobot.dashboard.core.WorkflowDetail
import com.attobot.dashboard.core.WorkflowList
import com.attobot.dashboard.core.WorkflowRow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** Polling cadence — matches the web app's REFRESH_MS (5 s). */
const val REFRESH_MS: Long = 5000L

/** 5 s for polling screens; 300 ms for the Workflows search debounce. */
private const val SEARCH_DEBOUNCE_MS: Long = 300L

// ---- UI state envelope -----------------------------------------------------

sealed interface UiState<out T> {
    data object Loading : UiState<Nothing>
    data class Ready<T>(val data: T, val refreshing: Boolean = false) : UiState<T>
    data class Error(val message: String) : UiState<Nothing>
}

/**
 * Base view model for every screen. Drives a [UiState] flow and (for polled
 * screens) loops [fetch] every [REFRESH_MS]. [refresh] is the pull-to-refresh
 * entry point; it flips on the refreshing indicator, background fetches do not
 * (so the spinner doesn't flash every 5 s).
 *
 * AuthException → "Unauthorized — token required" (the gate is the primary auth
 * handler; this is defensive). Any other failure becomes an Error cell.
 */
abstract class PollingViewModel<T>(
    private val poll: Boolean = true,
    private val intervalMs: Long = REFRESH_MS,
) : ViewModel() {

    protected val _state = MutableStateFlow<UiState<T>>(UiState.Loading)
    val state: StateFlow<UiState<T>> = _state.asStateFlow()

    private var pollJob: Job? = null

    init {
        if (poll) {
            pollJob = viewModelScope.launch(Dispatchers.IO) {
                while (isActive) {
                    runFetch(showRefreshing = false)
                    delay(intervalMs)
                }
            }
        } else {
            viewModelScope.launch(Dispatchers.IO) { runFetch(showRefreshing = false) }
        }
    }

    protected abstract suspend fun fetch(): T

    fun refresh() {
        viewModelScope.launch(Dispatchers.IO) { runFetch(showRefreshing = true) }
    }

    private suspend fun runFetch(showRefreshing: Boolean) {
        val prev = _state.value
        if (showRefreshing) {
            _state.value = when (prev) {
                is UiState.Ready -> UiState.Ready(prev.data, refreshing = true)
                else -> UiState.Loading
            }
        }
        try {
            _state.value = UiState.Ready(fetch(), refreshing = false)
        } catch (e: AuthException) {
            _state.value = UiState.Error("Unauthorized — token required")
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _state.value = UiState.Error(e.message ?: "Unknown error")
        }
    }

    override fun onCleared() {
        pollJob?.cancel()
        super.onCleared()
    }
}

// ---- Per-screen view models ------------------------------------------------

/** Overview + the recent-failed workflows list (two polled queries). */
class OverviewData(
    val overview: Overview,
    val failed: List<WorkflowRow>,
)

class OverviewViewModel : PollingViewModel<OverviewData>(poll = true) {
    override suspend fun fetch(): OverviewData =
        OverviewData(ApiProvider.overview(), ApiProvider.workflows(status = "failed", limit = 8).rows)
}

/** Workflows — filtered by status / type / agent / debounced search + paged. */
class WorkflowsViewModel : PollingViewModel<WorkflowList>(poll = true) {

    private val _status = MutableStateFlow("")
    val status: StateFlow<String> = _status.asStateFlow()
    private val _type = MutableStateFlow("")
    val type: StateFlow<String> = _type.asStateFlow()
    private val _agent = MutableStateFlow("")
    val agent: StateFlow<String> = _agent.asStateFlow()
    private val _q = MutableStateFlow("")
    val q: StateFlow<String> = _q.asStateFlow()
    private val _offset = MutableStateFlow(0)
    val offset: StateFlow<Int> = _offset.asStateFlow()

    private var qJob: Job? = null

    fun setStatus(v: String) { _status.value = v; _offset.value = 0; refresh() }
    fun setType(v: String) { _type.value = v; _offset.value = 0; refresh() }
    fun setAgent(v: String) { _agent.value = v; _offset.value = 0; refresh() }
    fun setOffset(n: Int) { _offset.value = n; refresh() }

    /** Debounce search by [SEARCH_DEBOUNCE_MS]; any keystroke resets paging. */
    fun setQ(v: String) {
        _q.value = v
        _offset.value = 0
        qJob?.cancel()
        qJob = viewModelScope.launch(Dispatchers.IO) {
            delay(SEARCH_DEBOUNCE_MS)
            refresh()
        }
    }

    /** Seed filters from a cross-link (Overview → Workflows?status=failed). */
    fun seed(status: String?, type: String?, agent: String?) {
        var changed = false
        if (status != null && _status.value != status) { _status.value = status; changed = true }
        if (type != null && _type.value != type) { _type.value = type; changed = true }
        if (agent != null && _agent.value != agent) { _agent.value = agent; changed = true }
        if (changed) { _offset.value = 0; refresh() }
    }

    override suspend fun fetch(): WorkflowList =
        ApiProvider.workflows(
            status = _status.value,
            type = _type.value,
            agent = _agent.value,
            q = _q.value,
            limit = PAGE_LIMIT,
            offset = _offset.value,
        )

    companion object { const val PAGE_LIMIT = 50 }
}

class WorkflowDetailViewModel(private val id: String) : PollingViewModel<WorkflowDetail>(poll = true) {
    override suspend fun fetch(): WorkflowDetail = ApiProvider.workflow(id)
}

class WorkflowDetailViewModelFactory(private val id: String) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T = WorkflowDetailViewModel(id) as T
}

/** Agents — not polled (cached ~60 s via [AgentsCache] for the filter chips). */
class AgentsViewModel : PollingViewModel<List<AgentRow>>(poll = false) {
    override suspend fun fetch(): List<AgentRow> = ApiProvider.agents()
}

/** Messages — per-agent, cursor-paged backwards via `before` (oldest id in page). */
class MessagesViewModel : PollingViewModel<List<MessageRow>>(poll = false) {

    private val _agentId = MutableStateFlow("")
    val agentId: StateFlow<String> = _agentId.asStateFlow()
    private val _before = MutableStateFlow<Long?>(null)

    fun setAgentId(v: String) {
        _agentId.value = v
        _before.value = null
        _state.value = UiState.Loading
        refresh()
    }

    fun loadOlder(before: Long) {
        _before.value = before
        refresh()
    }

    override suspend fun fetch(): List<MessageRow> {
        val a = _agentId.value
        if (a.isBlank()) return emptyList()
        return ApiProvider.messages(a, limit = 50, before = _before.value)
    }
}

abstract class AgentFilteredViewModel<T>(poll: Boolean) : PollingViewModel<T>(poll = poll) {
    private val _agentId = MutableStateFlow("")
    val agentId: StateFlow<String> = _agentId.asStateFlow()

    fun setAgentId(v: String) {
        _agentId.value = v
        _state.value = UiState.Loading
        refresh()
    }

    protected fun agentIdOrAll(): String? = _agentId.value.ifBlank { null }
}

class MemoryViewModel : AgentFilteredViewModel<List<MemoryRow>>(poll = false) {
    override suspend fun fetch(): List<MemoryRow> = ApiProvider.memory(agentIdOrAll())
}

class LifecycleViewModel : AgentFilteredViewModel<List<LifecycleRow>>(poll = true) {
    override suspend fun fetch(): List<LifecycleRow> = ApiProvider.lifecycle(agentIdOrAll(), limit = 200)
}

class ConfigViewModel : AgentFilteredViewModel<List<ConfigRow>>(poll = false) {
    override suspend fun fetch(): List<ConfigRow> = ApiProvider.config(agentIdOrAll())
}

class BlobsViewModel : AgentFilteredViewModel<List<BlobRow>>(poll = false) {
    override suspend fun fetch(): List<BlobRow> = ApiProvider.blobs(agentIdOrAll())
}

class UsersViewModel : PollingViewModel<List<UserRow>>(poll = false) {
    override suspend fun fetch(): List<UserRow> = ApiProvider.users()
}

// ---- Shared agents cache for AgentPills ------------------------------------

/**
 * A 60 s in-memory cache of the agents list, shared by every AgentPills row
 * (the analogue of TanStack Query's `["agents"]` query with staleTime 60 s in
 * the RN client — one network request serves all the filter chips).
 */
object AgentsCache {
    @Volatile private var cache: List<AgentRow> = emptyList()
    @Volatile private var fetchedAt: Long = 0L
    private val lock = Any()

    suspend fun get(force: Boolean = false): List<AgentRow> {
        val now = System.currentTimeMillis()
        if (!force && cache.isNotEmpty() && now - fetchedAt < 60_000L) return cache
        return synchronized(lock) {
            if (!force && cache.isNotEmpty() && System.currentTimeMillis() - fetchedAt < 60_000L) {
                cache
            } else {
                val fresh = try {
                    ApiProvider.agents()
                } catch (e: Exception) {
                    cache
                }
                cache = fresh
                fetchedAt = System.currentTimeMillis()
                fresh
            }
        }
    }

    fun snapshot(): List<AgentRow> = cache
}
