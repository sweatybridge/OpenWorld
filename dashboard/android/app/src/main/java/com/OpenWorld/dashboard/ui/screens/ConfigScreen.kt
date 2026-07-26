package com.OpenWorld.dashboard.ui.screens

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import com.OpenWorld.dashboard.core.ConfigRow
import com.OpenWorld.dashboard.core.timeAgo
import com.OpenWorld.dashboard.state.ConfigViewModel
import com.OpenWorld.dashboard.state.UiState
import com.OpenWorld.dashboard.ui.components.AgentPills
import com.OpenWorld.dashboard.ui.components.DataTable
import com.OpenWorld.dashboard.ui.components.ErrorState
import com.OpenWorld.dashboard.ui.components.JsonView
import com.OpenWorld.dashboard.ui.components.LoadingView
import com.OpenWorld.dashboard.ui.components.PullRefreshScreen
import com.OpenWorld.dashboard.ui.components.TableColumn
import com.OpenWorld.dashboard.ui.theme.accent
import com.OpenWorld.dashboard.ui.theme.muted
import com.OpenWorld.dashboard.ui.theme.text

@Composable
fun ConfigScreen(
    @Suppress("UNUSED_PARAMETER") navController: NavHostController,
    initialAgentId: String?,
) {
    val vm: ConfigViewModel = viewModel()
    LaunchedEffect(initialAgentId) {
        if (!initialAgentId.isNullOrEmpty()) vm.setAgentId(initialAgentId)
    }
    val state by vm.state.collectAsStateWithLifecycle()
    val agentId by vm.agentId.collectAsStateWithLifecycle()

    val s = state
    val refreshing = s is UiState.Ready && s.refreshing

    PullRefreshScreen(refreshing = refreshing, onRefresh = vm::refresh) {
        Text(
            "Config",
            color = text,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 12.dp),
        )
        AgentPills(agentId, vm::setAgentId)
        Text(
            "secrets are redacted server-side — use psql to read values",
            color = muted,
            fontSize = 12.sp,
            modifier = Modifier.padding(top = 0.dp, bottom = 12.dp),
        )
        when (s) {
            is UiState.Loading -> LoadingView()
            is UiState.Error -> ErrorState(s.message)
            is UiState.Ready -> DataTable(rows = s.data, columns = configColumns())
        }
    }
}

private fun configColumns(): List<TableColumn<ConfigRow>> = listOf(
    TableColumn(header = "agent", width = 70.dp) {
        Text("${it.agentId}", color = text, fontSize = 13.sp)
    },
    TableColumn(header = "key", width = 160.dp) {
        Text(it.key, color = accent, fontFamily = FontFamily.Monospace, fontSize = 12.sp, maxLines = 1)
    },
    TableColumn(header = "value", width = 240.dp) {
        if (it.secret) {
            Text(
                "•••••• (secret)",
                color = muted,
                fontStyle = FontStyle.Italic,
                fontSize = 13.sp,
            )
        } else {
            JsonView(it.value)
        }
    },
    TableColumn(header = "secret", width = 70.dp) {
        Text(if (it.secret) "yes" else "no", color = text, fontSize = 13.sp)
    },
    TableColumn(header = "updated", width = 90.dp) {
        Text(timeAgo(it.updatedAt), color = text, fontSize = 13.sp)
    },
)
