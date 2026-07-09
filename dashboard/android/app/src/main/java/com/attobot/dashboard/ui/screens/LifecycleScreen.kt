package com.attobot.dashboard.ui.screens

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import com.attobot.dashboard.core.LifecycleRow
import com.attobot.dashboard.core.timeAgo
import com.attobot.dashboard.state.LifecycleViewModel
import com.attobot.dashboard.state.UiState
import com.attobot.dashboard.ui.components.AgentPills
import com.attobot.dashboard.ui.components.DataTable
import com.attobot.dashboard.ui.components.ErrorState
import com.attobot.dashboard.ui.components.JsonView
import com.attobot.dashboard.ui.components.LoadingView
import com.attobot.dashboard.ui.components.PullRefreshScreen
import com.attobot.dashboard.ui.components.TableColumn
import com.attobot.dashboard.ui.theme.text

@Composable
fun LifecycleScreen(
    @Suppress("UNUSED_PARAMETER") navController: NavHostController,
    initialAgentId: String?,
) {
    val vm: LifecycleViewModel = viewModel()
    LaunchedEffect(initialAgentId) {
        if (!initialAgentId.isNullOrEmpty()) vm.setAgentId(initialAgentId)
    }
    val state by vm.state.collectAsStateWithLifecycle()
    val agentId by vm.agentId.collectAsStateWithLifecycle()

    val s = state
    val refreshing = s is UiState.Ready && s.refreshing

    PullRefreshScreen(refreshing = refreshing, onRefresh = vm::refresh) {
        Text(
            "Lifecycle",
            color = text,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 12.dp),
        )
        AgentPills(agentId, vm::setAgentId)
        when (s) {
            is UiState.Loading -> LoadingView()
            is UiState.Error -> ErrorState(s.message)
            is UiState.Ready -> DataTable(rows = s.data, columns = lifecycleColumns())
        }
    }
}

private fun lifecycleColumns(): List<TableColumn<LifecycleRow>> = listOf(
    TableColumn(header = "id", width = 70.dp) {
        Text("${it.id}", color = text, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
    },
    TableColumn(header = "agent", width = 70.dp) {
        Text("${it.agentId ?: "—"}", color = text, fontSize = 13.sp)
    },
    TableColumn(header = "event", width = 130.dp) {
        Text(it.event ?: "—", color = text, fontWeight = FontWeight.Bold, fontSize = 13.sp)
    },
    TableColumn(header = "detail", width = 240.dp) {
        JsonView(it.detail)
    },
    TableColumn(header = "time", width = 90.dp) {
        Text(timeAgo(it.createdAt), color = text, fontSize = 13.sp)
    },
)
