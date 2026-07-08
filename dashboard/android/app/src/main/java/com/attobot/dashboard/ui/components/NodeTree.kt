package com.attobot.dashboard.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.attobot.dashboard.core.InstanceNode
import com.attobot.dashboard.core.truncate
import com.attobot.dashboard.ui.theme.accent
import com.attobot.dashboard.ui.theme.muted
import com.attobot.dashboard.ui.theme.statusColor
import com.attobot.dashboard.ui.theme.warn

private val NODE_MARKER: Map<String, String> = mapOf(
    "completed" to "✓",
    "failed" to "✗",
    "running" to "⏳",
    "pending" to "○",
    "cancelled" to "✗",
)

/**
 * Recursive rendering of a pg_durable node graph. Same roots/childId logic as
 * the web/RN NodeTree: a node is a root when no other node points at it via
 * left_node / right_node; children follow those pointers.
 */
@Composable
fun NodeTree(nodes: List<InstanceNode>) {
    if (nodes.isEmpty()) {
        EmptyState("No nodes recorded for this instance.")
        return
    }
    val byId = remember(nodes) { nodes.associateBy { it.nodeId } }
    val childIds = remember(nodes) {
        buildSet {
            nodes.forEach { n ->
                n.leftNode?.let { add(it) }
                n.rightNode?.let { add(it) }
            }
        }
    }
    val roots = remember(nodes) { nodes.filter { it.nodeId !in childIds } }
    Column {
        roots.forEach { NodeRow(it, byId, 0) }
    }
}

@Composable
private fun NodeRow(node: InstanceNode, byId: Map<String, InstanceNode>, depth: Int) {
    var openResult by rememberSaveable { mutableStateOf(false) }
    val left = node.leftNode?.let { byId[it] }
    val right = node.rightNode?.let { byId[it] }
    val marker = NODE_MARKER[node.status ?: ""] ?: "•"
    val markerColor = statusColor(node.status)
    val queryOne = node.query?.let { truncate(it, 90) }.orEmpty()

    Column(Modifier.padding(start = (depth * 18).dp, top = 2.dp, bottom = 2.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Text(
                marker,
                color = markerColor,
                fontFamily = FontFamily.Monospace,
                fontSize = 13.sp,
                modifier = Modifier.width(14.dp),
            )
            Text(
                node.nodeType,
                color = accent,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.Monospace,
                fontSize = 13.sp,
            )
            if (node.resultName != null) {
                Text(
                    "|=> ${node.resultName}",
                    color = warn,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(start = 6.dp),
                )
            }
            if (queryOne.isNotEmpty()) {
                Text(
                    queryOne,
                    color = muted,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 13.sp,
                    maxLines = 1,
                    modifier = Modifier.padding(start = 6.dp),
                )
            }
        }
        if (node.result != null) {
            Text(
                if (openResult) "▾ result" else "▸ result",
                color = accent,
                fontSize = 12.sp,
                modifier = Modifier
                    .clickable { openResult = !openResult }
                    .padding(vertical = 2.dp),
            )
            if (openResult) {
                JsonView(node.result, defaultOpen = false)
            }
        }
        left?.let { NodeRow(it, byId, depth + 1) }
        right?.let { NodeRow(it, byId, depth + 1) }
    }
}
