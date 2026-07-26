package com.OpenWorld.dashboard.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import kotlinx.serialization.json.JsonElement
import com.OpenWorld.dashboard.core.Overview
import com.OpenWorld.dashboard.core.WorkflowRow
import com.OpenWorld.dashboard.core.fieldOr
import com.OpenWorld.dashboard.core.formatDateTime
import com.OpenWorld.dashboard.core.timeAgo
import com.OpenWorld.dashboard.state.OverviewViewModel
import com.OpenWorld.dashboard.state.UiState
import com.OpenWorld.dashboard.ui.components.OpenWorldCard
import com.OpenWorld.dashboard.ui.components.DataTable
import com.OpenWorld.dashboard.ui.components.EmptyState
import com.OpenWorld.dashboard.ui.components.ErrorState
import com.OpenWorld.dashboard.ui.components.KeyValue
import com.OpenWorld.dashboard.ui.components.LoadingView
import com.OpenWorld.dashboard.ui.components.PullRefreshScreen
import com.OpenWorld.dashboard.ui.components.StatusBadge
import com.OpenWorld.dashboard.ui.components.TableColumn
import com.OpenWorld.dashboard.ui.components.TypePill
import com.OpenWorld.dashboard.ui.nav.Routes
import com.OpenWorld.dashboard.ui.theme.accent
import com.OpenWorld.dashboard.ui.theme.border
import com.OpenWorld.dashboard.ui.theme.err
import com.OpenWorld.dashboard.ui.theme.muted
import com.OpenWorld.dashboard.ui.theme.ok
import com.OpenWorld.dashboard.ui.theme.panel
import com.OpenWorld.dashboard.ui.theme.text

@Composable
fun OverviewScreen(navController: NavHostController) {
    val vm: OverviewViewModel = viewModel()
    val state by vm.state.collectAsStateWithLifecycle()
    val s = state
    val refreshing = s is UiState.Ready && s.refreshing

    PullRefreshScreen(refreshing = refreshing, onRefresh = vm::refresh) {
        Text(
            "Overview",
            color = text,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 12.dp),
        )
        when (s) {
            is UiState.Loading -> LoadingView()
            is UiState.Error -> ErrorState(s.message)
            is UiState.Ready -> OverviewBody(s.data.overview, s.data.failed, navController)
        }
    }
}

@Composable
private fun OverviewBody(o: Overview, failed: List<WorkflowRow>, navController: NavHostController) {
    MetricGrid(o.metrics)

    OpenWorldCard(title = "pg_durable worker") {
        val w = o.worker
        if (w != null) {
            val alive = (w.ageSeconds ?: 999.0) < 15.0
            KeyValue(
                items = listOf(
                    "status" to {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Dot(if (alive) ok else err)
                            Text(
                                if (alive) "alive" else "stale / down",
                                color = text,
                                fontSize = 13.sp,
                                modifier = Modifier.padding(start = 8.dp),
                            )
                        }
                    },
                    "last heartbeat" to {
                        Text(
                            if (w.ageSeconds != null) "%.1fs ago".format(w.ageSeconds) else "—",
                            color = text,
                            fontSize = 13.sp,
                        )
                    },
                    "started" to {
                        Text(formatDateTime(w.startedAt), color = text, fontSize = 13.sp)
                    },
                ),
            )
        } else {
            EmptyState("Worker liveness unavailable.")
        }
    }

    OpenWorldCard(title = "By status") {
        if (o.byStatus.isEmpty()) {
            EmptyState("No instances.")
        } else {
            Column {
                o.byStatus.forEach { r ->
                    CountRow(
                        onClick = { navController.navigate(Routes.workflows(status = r.status)) },
                    ) {
                        StatusBadge(r.status)
                        Text(
                            r.count,
                            color = muted,
                            fontSize = 14.sp,
                            modifier = Modifier.padding(start = 10.dp),
                        )
                    }
                }
            }
        }
    }

    OpenWorldCard(title = "By type") {
        if (o.byType.isEmpty()) {
            EmptyState("No instances.")
        } else {
            Column {
                o.byType.forEach { r ->
                    CountRow(
                        onClick = { navController.navigate(Routes.workflows(type = r.type)) },
                    ) {
                        TypePill(r.type)
                        Text(
                            r.count,
                            color = muted,
                            fontSize = 14.sp,
                            modifier = Modifier.padding(start = 10.dp),
                        )
                    }
                }
            }
        }
    }

    OpenWorldCard(title = "Agents") {
        if (o.agents.isEmpty()) {
            EmptyState("No agents.")
        } else {
            Column {
                o.agents.forEach { a ->
                    CountRow(
                        onClick = { navController.navigate(Routes.withAgent("messages", a.id.toString())) },
                    ) {
                        Dot(if (a.enabled) ok else err)
                        Text(
                            a.slug,
                            color = text,
                            fontSize = 14.sp,
                            modifier = Modifier
                                .weight(1f)
                                .padding(start = 10.dp),
                        )
                    }
                }
            }
        }
    }

    OpenWorldCard(title = "Recent failed workflows") {
        DataTable(
            rows = failed,
            onRow = { navController.navigate(Routes.workflowDetail(it.id)) },
            columns = failedColumns(),
        )
    }
}

private fun failedColumns(): List<TableColumn<WorkflowRow>> = listOf(
    TableColumn(header = "id", width = 140.dp) {
        Text(it.id, color = accent, fontFamily = FontFamily.Monospace, fontSize = 12.sp, maxLines = 1)
    },
    TableColumn(header = "label", width = 200.dp) {
        Text(it.label, color = text, fontSize = 13.sp, maxLines = 1)
    },
    TableColumn(header = "type", width = 80.dp) {
        TypePill(it.type)
    },
    TableColumn(header = "status", width = 110.dp) {
        StatusBadge(it.status)
    },
    TableColumn(header = "updated", width = 90.dp) {
        Text(timeAgo(it.updatedAt), color = text, fontSize = 13.sp)
    },
)

@Composable
private fun MetricGrid(metrics: Map<String, JsonElement>?) {
    val tiles = listOf(
        "total instances" to (metrics?.fieldOr("total_instances", "—") ?: "—"),
        "running" to (metrics?.fieldOr("running_instances", "—") ?: "—"),
        "completed" to (metrics?.fieldOr("completed_instances", "—") ?: "—"),
        "failed" to (metrics?.fieldOr("failed_instances", "—") ?: "—"),
        "total executions" to (metrics?.fieldOr("total_executions", "—") ?: "—"),
        "total events" to (metrics?.fieldOr("total_events", "—") ?: "—"),
    )
    tiles.chunked(2).forEach { pair ->
        Row(
            Modifier
                .fillMaxWidth()
                .padding(bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            pair.forEach { (label, value) ->
                MetricTile(label = label, value = value, modifier = Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun MetricTile(label: String, value: String, modifier: Modifier = Modifier) {
    androidx.compose.material3.Surface(
        color = panel,
        shape = RoundedCornerShape(10.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, border),
        modifier = modifier,
    ) {
        Column(Modifier.padding(14.dp)) {
            Text(value, color = text, fontSize = 24.sp, fontWeight = FontWeight.Bold)
            Text(
                label,
                color = muted,
                fontSize = 12.sp,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

@Composable
private fun CountRow(onClick: () -> Unit, content: @Composable RowScope.() -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        content = content,
    )
}

@Composable
private fun Dot(color: Color) {
    Box(
        Modifier
            .size(9.dp)
            .clip(CircleShape)
            .background(color),
    )
}
