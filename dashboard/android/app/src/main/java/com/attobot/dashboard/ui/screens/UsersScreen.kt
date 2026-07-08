package com.attobot.dashboard.ui.screens

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
import com.attobot.dashboard.core.UserRow
import com.attobot.dashboard.core.timeAgo
import com.attobot.dashboard.state.UiState
import com.attobot.dashboard.ui.components.DataTable
import com.attobot.dashboard.ui.components.ErrorState
import com.attobot.dashboard.ui.components.LoadingView
import com.attobot.dashboard.ui.components.PullRefreshScreen
import com.attobot.dashboard.ui.components.TableColumn
import com.attobot.dashboard.ui.components.TypePill
import com.attobot.dashboard.ui.theme.text

@Composable
fun UsersScreen(@Suppress("UNUSED_PARAMETER") navController: NavHostController) {
    val vm: com.attobot.dashboard.state.UsersViewModel = viewModel()
    val state by vm.state.collectAsStateWithLifecycle()
    val s = state

    PullRefreshScreen(refreshing = false, onRefresh = null) {
        Text(
            "Users",
            color = text,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 12.dp),
        )
        when (s) {
            is UiState.Loading -> LoadingView()
            is UiState.Error -> ErrorState(s.message)
            is UiState.Ready -> DataTable(rows = s.data, columns = userColumns())
        }
    }
}

private fun userColumns(): List<TableColumn<UserRow>> = listOf(
    TableColumn(header = "id", width = 70.dp) {
        Text("${it.id}", color = text, fontFamily = FontFamily.Monospace, fontSize = 12.sp)
    },
    TableColumn(header = "channel", width = 110.dp) {
        Text(it.channel ?: "—", color = text, fontSize = 13.sp)
    },
    TableColumn(header = "external id", width = 150.dp) {
        Text(it.externalId ?: "—", color = text, fontFamily = FontFamily.Monospace, fontSize = 12.sp, maxLines = 1)
    },
    TableColumn(header = "username", width = 160.dp) {
        Text(it.username ?: it.displayName ?: "—", color = text, fontSize = 13.sp, maxLines = 1)
    },
    TableColumn(header = "tier", width = 90.dp) {
        TypePill(it.tier ?: "—")
    },
    TableColumn(header = "updated", width = 90.dp) {
        Text(timeAgo(it.updatedAt), color = text, fontSize = 13.sp)
    },
)
