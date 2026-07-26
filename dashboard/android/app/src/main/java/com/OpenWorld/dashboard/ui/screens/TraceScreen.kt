package com.OpenWorld.dashboard.ui.screens

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import com.OpenWorld.dashboard.core.TraceRow
import com.OpenWorld.dashboard.core.timeAgo
import com.OpenWorld.dashboard.state.TraceViewModel
import com.OpenWorld.dashboard.state.TraceViewModelFactory
import com.OpenWorld.dashboard.state.UiState
import com.OpenWorld.dashboard.ui.components.OpenWorldCard
import com.OpenWorld.dashboard.ui.components.DataTable
import com.OpenWorld.dashboard.ui.components.ErrorState
import com.OpenWorld.dashboard.ui.components.JsonView
import com.OpenWorld.dashboard.ui.components.LoadingView
import com.OpenWorld.dashboard.ui.components.PullRefreshScreen
import com.OpenWorld.dashboard.ui.components.StatusBadge
import com.OpenWorld.dashboard.ui.components.TableColumn
import com.OpenWorld.dashboard.ui.nav.Routes
import com.OpenWorld.dashboard.ui.theme.muted
import com.OpenWorld.dashboard.ui.theme.text

/**
 * Full turn trace for any message id. The server resolves the turn's trigger, so
 * this works from a user, assistant, or tool message alike. Tapping a row opens
 * that instance's WorkflowDetail.
 */
@Composable
fun TraceScreen(navController: NavHostController, messageId: Long) {
    val vm: TraceViewModel = viewModel(factory = TraceViewModelFactory(messageId))
    val state by vm.state.collectAsStateWithLifecycle()
    val s = state
    val refreshing = s is UiState.Ready && s.refreshing

    PullRefreshScreen(refreshing = refreshing, onRefresh = vm::refresh) {
        when (s) {
            is UiState.Loading -> LoadingView()
            is UiState.Error -> ErrorState(s.message)
            is UiState.Ready -> OpenWorldCard(title = "Correlated instances") {
                DataTable(
                    rows = s.data,
                    columns = traceColumns(),
                    onRow = { r -> navController.navigate(Routes.workflowDetail(r.instanceId)) },
                    emptyText = "No correlated instances for this turn.",
                )
            }
        }
    }
}

private fun traceColumns(): List<TableColumn<TraceRow>> = listOf(
    TableColumn(header = "kind", width = 90.dp) {
        Text(it.kind, color = muted, fontSize = 12.sp)
    },
    TableColumn(header = "instance", width = 110.dp) {
        Text(
            it.instanceId.take(8),
            color = text,
            fontFamily = FontFamily.Monospace,
            fontSize = 12.sp,
            maxLines = 1,
        )
    },
    TableColumn(header = "message", width = 90.dp) {
        Text(it.messageId?.let { m -> "#$m" } ?: "—", color = text, fontSize = 13.sp)
    },
    TableColumn(header = "tool call", width = 150.dp) {
        val tc = it.toolCallId
        if (tc != null) {
            Text(tc, color = text, fontFamily = FontFamily.Monospace, fontSize = 12.sp, maxLines = 1)
        } else {
            Text("—", color = text, fontSize = 13.sp)
        }
    },
    TableColumn(header = "status", width = 110.dp) { StatusBadge(it.status) },
    TableColumn(header = "updated", width = 100.dp) {
        Text(timeAgo(it.updatedAt), color = text, fontSize = 13.sp)
    },
    TableColumn(header = "result", width = 160.dp) { JsonView(it.result) },
)
