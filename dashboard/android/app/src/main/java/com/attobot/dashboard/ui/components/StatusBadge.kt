package com.attobot.dashboard.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.attobot.dashboard.ui.theme.border
import com.attobot.dashboard.ui.theme.panel2
import com.attobot.dashboard.ui.theme.statusColor
import com.attobot.dashboard.ui.theme.text

/**
 * Lowercased pill mirroring the web `.badge` / `.pill`. Status pills are tinted
 * by the status colour (web `.st-*`); type pills are neutral. Port of RN
 * <Badge/> (StatusBadge + TypePill).
 */
@Composable
fun StatusBadge(status: String?) {
    val v = (status ?: "unknown").toString()
    val c = statusColor(v)
    Surface(
        shape = RoundedCornerShape(10.dp),
        border = BorderStroke(1.dp, c),
        color = panel2,
    ) {
        Text(
            v.lowercase(),
            color = c,
            fontSize = 12.sp,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 1.dp),
        )
    }
}

@Composable
fun TypePill(type: String) {
    Surface(
        shape = RoundedCornerShape(10.dp),
        border = BorderStroke(1.dp, border),
        color = panel2,
    ) {
        Text(
            type.lowercase(),
            color = text,
            fontSize = 12.sp,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 1.dp),
        )
    }
}
