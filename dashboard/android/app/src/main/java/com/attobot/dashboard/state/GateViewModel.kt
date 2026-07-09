package com.attobot.dashboard.state

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.attobot.dashboard.core.ApiException
import com.attobot.dashboard.core.ApiProvider
import com.attobot.dashboard.core.AuthException
import com.attobot.dashboard.core.Credentials
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Auth gate — the Android counterpart of the RN `RootNav` gate logic.
 *
 * Phase transitions mirror the web AuthShell / RN gate:
 *  - no base URL configured           → [NeedSetup]([Reason.FirstRun])
 *  - probe returns 401                → [NeedSetup]([Reason.Token])
 *  - probe fails for any other reason → [BackendDown]
 *  - probe succeeds                   → [Ready]
 *
 * `reload()` re-probes; `edit()` flips straight to the Setup screen; `save()`
 * persists credentials and re-probes; `clearToken()` wipes the token and
 * re-probes (→ NeedSetup(Token) when the server is token-gated).
 */
sealed interface GatePhase {
    data object Loading : GatePhase
    data class NeedSetup(val reason: Reason) : GatePhase
    data class BackendDown(val message: String) : GatePhase
    data object Ready : GatePhase
}

enum class Reason { FirstRun, Token, Edit }

class GateViewModel : ViewModel() {

    private val _phase = MutableStateFlow<GatePhase>(GatePhase.Loading)
    val phase: StateFlow<GatePhase> = _phase.asStateFlow()

    init {
        probe()
    }

    private fun probe() {
        _phase.value = GatePhase.Loading
        viewModelScope.launch(Dispatchers.IO) {
            Credentials.load()
            if (!Credentials.hasBaseUrl()) {
                _phase.value = GatePhase.NeedSetup(Reason.FirstRun)
                return@launch
            }
            try {
                ApiProvider.overview()
                _phase.value = GatePhase.Ready
            } catch (e: AuthException) {
                _phase.value = GatePhase.NeedSetup(Reason.Token)
            } catch (e: Exception) {
                val message = (e as? ApiException)?.message ?: e.message ?: "Unknown error"
                _phase.value = GatePhase.BackendDown(message)
            }
        }
    }

    fun reload() = probe()

    fun edit() {
        _phase.value = GatePhase.NeedSetup(Reason.Edit)
    }

    /** Cancel an edit (only offered when a base URL is already configured). */
    fun cancelEdit() = probe()

    fun save(base: String, token: String) {
        viewModelScope.launch(Dispatchers.IO) {
            Credentials.save(base, token)
            probe()
        }
    }

    fun clearToken() {
        viewModelScope.launch(Dispatchers.IO) {
            Credentials.clearToken()
            probe()
        }
    }
}
