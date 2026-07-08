package com.attobot.dashboard.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.attobot.dashboard.ui.theme.border
import com.attobot.dashboard.ui.theme.muted
import com.attobot.dashboard.ui.theme.panel2

/** A table column: header label, fixed [width], and the cell renderer. */
data class TableColumn<T>(
    val header: String,
    val width: Dp,
    val cell: @Composable RowScope.(T) -> Unit,
)

/**
 * Wide tables scroll horizontally as a block, exactly like the web/RN tables.
 * Rows render as a flat list (admin views are small enough that lazy
 * virtualisation isn't worth the nested-scroll complexity). Rows are tappable
 * when [onRow] is supplied.
 */
@Composable
fun <T> DataTable(
    columns: List<TableColumn<T>>,
    rows: List<T>,
    onRow: ((T) -> Unit)? = null,
    emptyText: String = "No rows.",
) {
    val tableWidth = columns.sumOf { it.width.value.toDouble() }.dp
    val scroll = rememberScrollState()
    Column(
        Modifier
            .fillMaxWidth()
            .horizontalScroll(scroll)
            .width(tableWidth),
    ) {
        // Header row (panel2 background).
        Row(Modifier.fillMaxWidth().background(panel2)) {
            columns.forEach { col ->
                Box(
                    Modifier
                        .width(col.width)
                        .padding(horizontal = 10.dp, vertical = 8.dp),
                ) {
                    Text(
                        col.header,
                        color = muted,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        HorizontalDivider(color = border)
        if (rows.isEmpty()) {
            Text(
                emptyText,
                color = muted,
                fontSize = 13.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
            )
        } else {
            rows.forEachIndexed { i, row ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable(enabled = onRow != null) { onRow?.invoke(row) },
                ) {
                    val rowScope = this
                    columns.forEach { col ->
                        Box(
                            Modifier
                                .width(col.width)
                                .padding(horizontal = 10.dp, vertical = 8.dp),
                            contentAlignment = Alignment.CenterStart,
                        ) {
                            with(rowScope) { col.cell(row) }
                        }
                    }
                }
                if (i < rows.lastIndex) {
                    HorizontalDivider(color = border)
                }
            }
        }
    }
}
