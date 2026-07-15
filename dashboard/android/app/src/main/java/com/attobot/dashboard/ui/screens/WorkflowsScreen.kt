package com.attobot.dashboard.ui.screens

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import com.attobot.dashboard.core.WorkflowRow
import com.attobot.dashboard.core.timeAgo
import com.attobot.dashboard.state.UiState
import com.attobot.dashboard.state.WorkflowsViewModel
import com.attobot.dashboard.ui.components.AgentPills
import com.attobot.dashboard.ui.components.DataTable
import com.attobot.dashboard.ui.components.ErrorState
import com.attobot.dashboard.ui.components.FilterPills
import com.attobot.dashboard.ui.components.LoadingView
import com.attobot.dashboard.ui.components.Pager
import com.attobot.dashboard.ui.components.PullRefreshScreen
import com.attobot.dashboard.ui.components.STATUS_OPTIONS
import com.attobot.dashboard.ui.components.StatusBadge
import com.attobot.dashboard.ui.components.TableColumn
import com.attobot.dashboard.ui.components.TYPE_OPTIONS
import com.attobot.dashboard.ui.components.TypePill
import com.attobot.dashboard.ui.nav.Routes
import com.attobot.dashboard.ui.theme.accent
import com.attobot.dashboard.ui.theme.border
import com.attobot.dashboard.ui.theme.bg
import com.attobot.dashboard.ui.theme.muted
import com.attobot.dashboard.ui.theme.text

@Composable
fun WorkflowsScreen(
    navController: NavHostController,
    status: String?,
    type: String?,
    agent: String?,
) {
    val vm: WorkflowsViewModel = viewModel()
    // Re-seed filters when navigated here with new params (Overview → by status).
    LaunchedEffect(status, type, agent) {
        vm.seed(status, type, agent)
    }

    val state by vm.state.collectAsStateWithLifecycle()
    val fStatus by vm.status.collectAsStateWithLifecycle()
    val fType by vm.type.collectAsStateWithLifecycle()
    val fAgent by vm.agent.collectAsStateWithLifecycle()
    val fQ by vm.q.collectAsStateWithLifecycle()
    val fOffset by vm.offset.collectAsStateWithLifecycle()

    val s = state
    val refreshing = s is UiState.Ready && s.refreshing

    PullRefreshScreen(refreshing = refreshing, onRefresh = vm::refresh) {
        Text(
            "Workflows",
            color = text,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 12.dp),
        )

        FilterPills(STATUS_OPTIONS, fStatus, vm::setStatus, allLabel = "any status")
        FilterPills(TYPE_OPTIONS, fType, vm::setType, allLabel = "any type")
        AgentPills(fAgent, vm::setAgent)

        SearchField(
            value = fQ,
            onValueChange = vm::setQ,
            placeholder = "search label / id…",
            modifier = Modifier.padding(vertical = 12.dp),
        )

        when (s) {
            is UiState.Loading -> LoadingView()
            is UiState.Error -> ErrorState(s.message)
            is UiState.Ready -> {
                DataTable(
                    rows = s.data.rows,
                    onRow = { navController.navigate(Routes.workflowDetail(it.id)) },
                    columns = workflowColumns(),
                )
                Pager(
                    offset = fOffset,
                    limit = WorkflowsViewModel.PAGE_LIMIT,
                    total = s.data.total,
                    onPage = vm::setOffset,
                )
            }
        }
    }
}

private fun workflowColumns(): List<TableColumn<WorkflowRow>> = listOf(
    TableColumn(header = "id", width = 150.dp) {
        Text(it.id, color = accent, fontFamily = FontFamily.Monospace, fontSize = 12.sp, maxLines = 1)
    },
    TableColumn(header = "label", width = 200.dp) {
        Text(it.label, color = text, fontSize = 13.sp, maxLines = 1)
    },
    TableColumn(header = "type", width = 80.dp) {
        TypePill(it.type)
    },
    TableColumn(header = "agent", width = 90.dp) {
        Text(it.agent ?: "—", color = text, fontSize = 13.sp)
    },
    TableColumn(header = "status", width = 110.dp) {
        StatusBadge(it.status)
    },
    TableColumn(header = "updated", width = 90.dp) {
        Text(timeAgo(it.updatedAt), color = text, fontSize = 13.sp)
    },
)

@Composable
private fun SearchField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier.fillMaxWidth(),
        singleLine = true,
        placeholder = { Text(placeholder, color = muted) },
        textStyle = TextStyle(color = text, fontSize = 13.sp),
        shape = RoundedCornerShape(6.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = text,
            unfocusedTextColor = text,
            focusedContainerColor = bg,
            unfocusedContainerColor = bg,
            focusedBorderColor = accent,
            unfocusedBorderColor = border,
            cursorColor = accent,
            focusedPlaceholderColor = muted,
            unfocusedPlaceholderColor = muted,
        ),
    )
}
