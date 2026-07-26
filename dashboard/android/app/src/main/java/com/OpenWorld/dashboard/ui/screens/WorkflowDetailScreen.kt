package com.OpenWorld.dashboard.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import com.OpenWorld.dashboard.core.WorkflowDetail
import com.OpenWorld.dashboard.core.field
import com.OpenWorld.dashboard.core.fieldOr
import com.OpenWorld.dashboard.core.formatMs
import com.OpenWorld.dashboard.core.messageIdFromLabel
import com.OpenWorld.dashboard.state.UiState
import com.OpenWorld.dashboard.state.WorkflowDetailViewModel
import com.OpenWorld.dashboard.state.WorkflowDetailViewModelFactory
import com.OpenWorld.dashboard.ui.components.OpenWorldCard
import com.OpenWorld.dashboard.ui.components.DataTable
import com.OpenWorld.dashboard.ui.components.EmptyState
import com.OpenWorld.dashboard.ui.components.ErrorState
import com.OpenWorld.dashboard.ui.components.JsonView
import com.OpenWorld.dashboard.ui.components.KeyValue
import com.OpenWorld.dashboard.ui.components.LoadingView
import com.OpenWorld.dashboard.ui.components.NodeTree
import com.OpenWorld.dashboard.ui.components.PullRefreshScreen
import com.OpenWorld.dashboard.ui.components.StatusBadge
import com.OpenWorld.dashboard.ui.components.TableColumn
import com.OpenWorld.dashboard.ui.nav.Routes
import com.OpenWorld.dashboard.ui.theme.accent
import com.OpenWorld.dashboard.ui.theme.border
import com.OpenWorld.dashboard.ui.theme.muted
import com.OpenWorld.dashboard.ui.theme.panel2
import com.OpenWorld.dashboard.ui.theme.text

@Composable
fun WorkflowDetailScreen(
    @Suppress("UNUSED_PARAMETER") navController: NavHostController,
    id: String,
) {
    val vm: WorkflowDetailViewModel = viewModel(factory = WorkflowDetailViewModelFactory(id))
    val state by vm.state.collectAsStateWithLifecycle()
    val s = state
    val refreshing = s is UiState.Ready && s.refreshing

    PullRefreshScreen(refreshing = refreshing, onRefresh = vm::refresh) {
        when (s) {
            is UiState.Loading -> LoadingView()
            is UiState.Error -> ErrorState(s.message)
            is UiState.Ready -> DetailBody(navController, id, s.data)
        }
    }
}

@Composable
private fun DetailBody(navController: NavHostController, id: String, d: WorkflowDetail) {
    val info = d.info
    val label = info?.fieldOr("label", id) ?: id
    val statusStr = info?.fieldOr("status", "") ?: ""
    val traceMsgId = messageIdFromLabel(label)
    val currentNodes = d.nodes.filter { it.executionId == d.currentExecutionId }
    var flipped by rememberSaveable { mutableStateOf(false) }

    Column {
        Text(
            id,
            color = text,
            fontFamily = FontFamily.Monospace,
            fontSize = 15.sp,
            fontWeight = FontWeight.Bold,
        )
        Row(
            Modifier.padding(top = 4.dp, bottom = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                label,
                color = muted,
                fontSize = 13.sp,
                modifier = Modifier.padding(end = 10.dp),
            )
            StatusBadge(statusStr)
        }

        OpenWorldCard(title = "Instance info") {
            KeyValue(
                items = listOf(
                    "status" to { StatusBadge(statusStr) },
                    "label" to { Text(info?.fieldOr("label", "—") ?: "—", color = text, fontSize = 13.sp) },
                    "function" to {
                        Text(
                            info?.fieldOr("function_name", "—") ?: "—",
                            color = text,
                            fontFamily = FontFamily.Monospace,
                            fontSize = 12.sp,
                        )
                    },
                    "version" to { Text(info?.fieldOr("function_version", "—") ?: "—", color = text, fontSize = 13.sp) },
                    "current execution" to {
                        Text(
                            d.currentExecutionId ?: "—",
                            color = text,
                            fontFamily = FontFamily.Monospace,
                            fontSize = 12.sp,
                        )
                    },
                    "output" to { JsonView(info?.get("output")) },
                ),
            )
        }

        OpenWorldCard(title = "Final result") {
            JsonView(d.result, defaultOpen = true)
        }

        val graphTitle = if (currentNodes.size != d.nodes.size && d.currentExecutionId != null) {
            "Node graph · execution ${d.currentExecutionId}"
        } else {
            "Node graph"
        }
        OpenWorldCard(
            title = graphTitle,
            right = {
                Text(
                    if (flipped) "⇅ execution" else "⇅ plan",
                    color = accent,
                    fontSize = 12.sp,
                    modifier = Modifier.clickable { flipped = !flipped },
                )
            },
        ) {
            NodeTree(currentNodes, flipped = flipped)
        }

        OpenWorldCard(title = "Executions") {
            DataTable(rows = d.executions, columns = executionColumns())
        }

        if (traceMsgId != null) {
            OpenWorldCard(title = "Turn trace · msg #$traceMsgId") {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { navController.navigate(Routes.trace(traceMsgId)) }
                        .padding(vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Open turn trace", color = accent, fontSize = 13.sp)
                    Text("›", color = muted, fontSize = 14.sp)
                }
            }
        }

        if (!d.explain.isNullOrBlank()) {
            OpenWorldCard(title = "df.explain") {
                androidx.compose.material3.Surface(
                    color = panel2,
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(6.dp),
                    border = androidx.compose.foundation.BorderStroke(1.dp, border),
                ) {
                    Text(
                        d.explain,
                        color = text,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp,
                        modifier = Modifier.padding(10.dp),
                    )
                }
            }
        }
    }
}

private fun executionColumns(): List<TableColumn<Map<String, kotlinx.serialization.json.JsonElement>>> = listOf(
    TableColumn(header = "execution", width = 150.dp) {
        Text(
            it.fieldOr("execution_id", "—"),
            color = text,
            fontFamily = FontFamily.Monospace,
            fontSize = 12.sp,
            maxLines = 1,
        )
    },
    TableColumn(header = "status", width = 110.dp) {
        StatusBadge(it.fieldOr("status", ""))
    },
    TableColumn(header = "events", width = 80.dp) {
        Text(it.fieldOr("event_count", "—"), color = text, fontSize = 13.sp)
    },
    TableColumn(header = "duration", width = 90.dp) {
        Text(
            formatMs(it.field("duration_ms")?.toDoubleOrNull()),
            color = text,
            fontSize = 13.sp,
        )
    },
    TableColumn(header = "output", width = 220.dp) {
        JsonView(it["output"])
    },
)
