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
import com.attobot.dashboard.core.IndexRow
import com.attobot.dashboard.state.IndexesViewModel
import com.attobot.dashboard.state.UiState
import com.attobot.dashboard.ui.components.DataTable
import com.attobot.dashboard.ui.components.ErrorState
import com.attobot.dashboard.ui.components.FilterPills
import com.attobot.dashboard.ui.components.LoadingView
import com.attobot.dashboard.ui.components.PullRefreshScreen
import com.attobot.dashboard.ui.components.TableColumn
import com.attobot.dashboard.ui.components.TypePill
import com.attobot.dashboard.ui.theme.accent
import com.attobot.dashboard.ui.theme.muted
import com.attobot.dashboard.ui.theme.text

/**
 * Database indexes across all non-system schemas (attobot, df, …), including
 * pgvector's hnsw/ivfflat access methods. The schema filter is derived
 * client-side from the fetched rows (mirrors the web Indexes page).
 */
@Composable
fun IndexesScreen(@Suppress("UNUSED_PARAMETER") navController: NavHostController) {
    val vm: IndexesViewModel = viewModel()
    val state by vm.state.collectAsStateWithLifecycle()
    val schema by vm.schema.collectAsStateWithLifecycle()
    val s = state

    val all = (s as? UiState.Ready)?.data ?: emptyList()
    val schemas = all.map { it.schemaName }.distinct().sorted()
    val rows = if (schema.isBlank()) all else all.filter { it.schemaName == schema }

    PullRefreshScreen(refreshing = false, onRefresh = null) {
        Text(
            "Indexes",
            color = text,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 12.dp),
        )
        FilterPills(options = schemas, value = schema, onSelect = vm::setSchema, allLabel = "all schemas")
        Text(
            "${rows.size} index${if (rows.size == 1) "" else "es"}",
            color = muted,
            fontSize = 12.sp,
            modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
        )
        when (s) {
            is UiState.Loading -> LoadingView()
            is UiState.Error -> ErrorState(s.message)
            is UiState.Ready -> DataTable(rows = rows, columns = indexColumns())
        }
    }
}

private fun indexColumns(): List<TableColumn<IndexRow>> = listOf(
    TableColumn(header = "schema", width = 90.dp) {
        Text(it.schemaName, color = text, fontFamily = FontFamily.Monospace, fontSize = 12.sp, maxLines = 1)
    },
    TableColumn(header = "table", width = 110.dp) {
        Text(it.tableName, color = text, fontFamily = FontFamily.Monospace, fontSize = 12.sp, maxLines = 1)
    },
    TableColumn(header = "index", width = 150.dp) {
        Text(it.indexName, color = accent, fontFamily = FontFamily.Monospace, fontSize = 12.sp, maxLines = 1)
    },
    TableColumn(header = "type", width = 80.dp) {
        TypePill(it.indexType)
    },
    TableColumn(header = "flags", width = 80.dp) {
        when {
            it.isPrimary -> TypePill("PK")
            it.isUnique -> TypePill("UNIQUE")
            else -> Text("—", color = muted, fontSize = 13.sp)
        }
    },
    TableColumn(header = "size", width = 90.dp) {
        Text(it.size, color = text, fontSize = 13.sp)
    },
    TableColumn(header = "scans", width = 90.dp) {
        Text(it.scans, color = text, fontSize = 13.sp)
    },
    TableColumn(header = "definition", width = 280.dp) {
        Text(it.definition, color = muted, fontFamily = FontFamily.Monospace, fontSize = 11.sp, maxLines = 2)
    },
)
