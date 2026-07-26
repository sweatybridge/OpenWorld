package com.OpenWorld.dashboard.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.OpenWorld.dashboard.state.AgentsCache
import com.OpenWorld.dashboard.ui.theme.accent
import com.OpenWorld.dashboard.ui.theme.border
import com.OpenWorld.dashboard.ui.theme.muted
import com.OpenWorld.dashboard.ui.theme.panel
import com.OpenWorld.dashboard.ui.theme.panel2
import com.OpenWorld.dashboard.ui.theme.text

/** Filter option sets — match the web top-nav filter dropdowns. */
val STATUS_OPTIONS: List<String> = listOf("pending", "running", "completed", "failed", "cancelled")
val TYPE_OPTIONS: List<String> = listOf("loop", "inbox", "cron", "send", "tool", "typing", "other")

data class PillOption(val value: String, val label: String)

/** Horizontally-scrolling filter chips — the mobile analogue of the web selects. */
@Composable
fun FilterPills(
    options: List<String>,
    value: String,
    onSelect: (String) -> Unit,
    allLabel: String = "all",
) {
    val all = listOf(PillOption("", allLabel)) + options.map { PillOption(it, it) }
    Pills(all, value, onSelect)
}

/** Agent filter chips, backed by the shared 60 s [AgentsCache]. */
@Composable
fun AgentPills(
    value: String,
    onSelect: (String) -> Unit,
) {
    val agents by produceState(initialValue = AgentsCache.snapshot()) {
        this.value = AgentsCache.get()
    }
    val opts = listOf(PillOption("", "all agents")) +
        agents.map { PillOption(it.id.toString(), it.slug) }
    Pills(opts, value, onSelect)
}

@Composable
private fun Pills(options: List<PillOption>, value: String, onSelect: (String) -> Unit) {
    Row(
        Modifier
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 6.dp),
    ) {
        options.forEach { o ->
            val active = o.value == value
            Surface(
                shape = RoundedCornerShape(14.dp),
                border = BorderStroke(1.dp, if (active) accent else border),
                color = if (active) panel2 else panel,
                modifier = Modifier
                    .padding(end = 8.dp)
                    .clickable { onSelect(o.value) },
            ) {
                Text(
                    o.label,
                    color = if (active) text else muted,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 5.dp),
                )
            }
        }
    }
}
