package com.attobot.dashboard.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.attobot.dashboard.ui.theme.accent
import com.attobot.dashboard.ui.theme.border
import com.attobot.dashboard.ui.theme.muted
import com.attobot.dashboard.ui.theme.panel
import kotlin.math.ceil
import kotlin.math.max

/** Prev/next pager mirroring the RN <Pager/>. */
@Composable
fun Pager(
    offset: Int,
    limit: Int,
    total: Int,
    onPage: (Int) -> Unit,
) {
    val page = offset / limit + 1
    val pages = max(1, ceil(total.toDouble() / limit).toInt())
    Row(
        Modifier
            .fillMaxWidth()
            .padding(top = 14.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PagerButton("‹ prev", enabled = offset > 0) { onPage(max(0, offset - limit)) }
        Text(
            "page $page / $pages · $total total",
            color = muted,
            fontSize = 13.sp,
            modifier = Modifier.padding(horizontal = 14.dp),
        )
        PagerButton("next ›", enabled = offset + limit < total) { onPage(offset + limit) }
    }
}

@Composable
private fun PagerButton(
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(6.dp),
        border = BorderStroke(1.dp, border),
        color = panel,
        modifier = Modifier.clickable(enabled = enabled, onClick = onClick),
    ) {
        Text(
            label,
            color = if (enabled) accent else muted,
            fontSize = 13.sp,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
        )
    }
}
