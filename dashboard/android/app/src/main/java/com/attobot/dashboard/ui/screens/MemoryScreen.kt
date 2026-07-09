package com.attobot.dashboard.ui.screens

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import com.attobot.dashboard.core.MemoryRow
import com.attobot.dashboard.core.timeAgo
import com.attobot.dashboard.core.truncate
import com.attobot.dashboard.state.MemoryViewModel
import com.attobot.dashboard.state.UiState
import com.attobot.dashboard.ui.components.AgentPills
import com.attobot.dashboard.ui.components.DataTable
import com.attobot.dashboard.ui.components.ErrorState
import com.attobot.dashboard.ui.components.LoadingView
import com.attobot.dashboard.ui.components.PullRefreshScreen
import com.attobot.dashboard.ui.components.TableColumn
import com.attobot.dashboard.ui.theme.accent
import com.attobot.dashboard.ui.theme.err
import com.attobot.dashboard.ui.theme.ok
import com.attobot.dashboard.ui.theme.text

@Composable
fun MemoryScreen(
    @Suppress("UNUSED_PARAMETER") navController: NavHostController,
    initialAgentId: String?,
) {
    val vm: MemoryViewModel = viewModel()
    LaunchedEffect(initialAgentId) {
        if (!initialAgentId.isNullOrEmpty()) vm.setAgentId(initialAgentId)
    }
    val state by vm.state.collectAsStateWithLifecycle()
    val agentId by vm.agentId.collectAsStateWithLifecycle()

    val s = state
    val refreshing = s is UiState.Ready && s.refreshing

    PullRefreshScreen(refreshing = refreshing, onRefresh = vm::refresh) {
        Text(
            "Memory",
            color = text,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 12.dp),
        )
        AgentPills(agentId, vm::setAgentId)
        when (s) {
            is UiState.Loading -> LoadingView()
            is UiState.Error -> ErrorState(s.message)
            is UiState.Ready -> DataTable(rows = s.data, columns = memoryColumns())
        }
    }
}

private fun memoryColumns(): List<TableColumn<MemoryRow>> = listOf(
    TableColumn(header = "id", width = 80.dp) {
        Text("${it.id}", color = accent, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
    },
    TableColumn(header = "agent", width = 70.dp) {
        Text("${it.agentId}", color = text, fontSize = 13.sp)
    },
    TableColumn(header = "content", width = 220.dp) {
        Text(
            truncate(it.content, 160),
            color = text,
            fontSize = 13.sp,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
    },
    TableColumn(header = "on", width = 40.dp) {
        val on = it.enabled == true
        Text(if (on) "●" else "○", color = if (on) ok else err, fontSize = 13.sp)
    },
    TableColumn(header = "sources", width = 80.dp) {
        Text("${it.sourceMessageIds?.size ?: 0}", color = text, fontSize = 13.sp)
    },
    TableColumn(header = "updated", width = 90.dp) {
        Text(timeAgo(it.updatedAt), color = text, fontSize = 13.sp)
    },
)
