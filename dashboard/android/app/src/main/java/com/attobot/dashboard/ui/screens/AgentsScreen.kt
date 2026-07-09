package com.attobot.dashboard.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import com.attobot.dashboard.core.AgentRow
import com.attobot.dashboard.core.timeAgo
import com.attobot.dashboard.state.AgentsViewModel
import com.attobot.dashboard.state.UiState
import com.attobot.dashboard.ui.components.DataTable
import com.attobot.dashboard.ui.components.ErrorState
import com.attobot.dashboard.ui.components.LoadingView
import com.attobot.dashboard.ui.components.PullRefreshScreen
import com.attobot.dashboard.ui.components.TableColumn
import com.attobot.dashboard.ui.nav.Routes
import com.attobot.dashboard.ui.theme.accent
import com.attobot.dashboard.ui.theme.err
import com.attobot.dashboard.ui.theme.muted
import com.attobot.dashboard.ui.theme.ok
import com.attobot.dashboard.ui.theme.text

@Composable
fun AgentsScreen(navController: NavHostController) {
    val vm: AgentsViewModel = viewModel()
    val state by vm.state.collectAsStateWithLifecycle()
    val s = state

    PullRefreshScreen(refreshing = false, onRefresh = null) {
        Text(
            "Agents",
            color = text,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 12.dp),
        )
        when (s) {
            is UiState.Loading -> LoadingView()
            is UiState.Error -> ErrorState(s.message)
            is UiState.Ready -> DataTable(
                rows = s.data,
                onRow = { navController.navigate(Routes.withAgent("messages", it.id.toString())) },
                columns = agentColumns(),
            )
        }
    }
}

private fun agentColumns(): List<TableColumn<AgentRow>> = listOf(
    TableColumn(header = "slug", width = 120.dp) {
        Text(it.slug, color = accent, fontWeight = FontWeight.Bold, fontSize = 13.sp, maxLines = 1)
    },
    TableColumn(header = "on", width = 40.dp) {
        Text(if (it.enabled) "●" else "○", color = if (it.enabled) ok else err, fontSize = 13.sp)
    },
    TableColumn(header = "model", width = 150.dp) {
        Column {
            Text(it.modelName ?: "—", color = text, fontSize = 13.sp, maxLines = 2)
            Text(it.apiBase ?: "", color = muted, fontSize = 11.sp, maxLines = 1)
        }
    },
    TableColumn(header = "max turn", width = 80.dp) {
        Text("${it.maxTurn}", color = text, fontSize = 13.sp)
    },
    TableColumn(header = "ctx tokens", width = 100.dp) {
        Text(it.contextTokens?.toString() ?: "—", color = text, fontSize = 13.sp)
    },
    TableColumn(header = "temp / effort", width = 120.dp) {
        Text("${it.temperature ?: "—"} / ${it.reasoningEffort ?: "—"}", color = text, fontSize = 13.sp)
    },
    TableColumn(header = "messages", width = 90.dp) {
        Text(it.msgCount, color = text, fontSize = 13.sp)
    },
    TableColumn(header = "memory", width = 80.dp) {
        Text(it.memCount, color = text, fontSize = 13.sp)
    },
    TableColumn(header = "workflows", width = 90.dp) {
        Text(it.wfCount, color = text, fontSize = 13.sp)
    },
    TableColumn(header = "updated", width = 90.dp) {
        Text(timeAgo(it.updatedAt), color = text, fontSize = 13.sp)
    },
)
