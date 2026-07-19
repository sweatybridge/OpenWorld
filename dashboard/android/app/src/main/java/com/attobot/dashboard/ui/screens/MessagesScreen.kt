package com.attobot.dashboard.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import com.attobot.dashboard.core.MessageRow
import com.attobot.dashboard.core.timeAgo
import com.attobot.dashboard.state.AgentsCache
import com.attobot.dashboard.state.MessagesViewModel
import com.attobot.dashboard.state.UiState
import com.attobot.dashboard.ui.components.AgentPills
import com.attobot.dashboard.ui.components.EmptyState
import com.attobot.dashboard.ui.components.ErrorState
import com.attobot.dashboard.ui.components.JsonText
import com.attobot.dashboard.ui.components.JsonView
import com.attobot.dashboard.ui.components.LoadingView
import com.attobot.dashboard.ui.components.PullRefreshScreen
import com.attobot.dashboard.ui.nav.Routes
import com.attobot.dashboard.ui.theme.accent
import com.attobot.dashboard.ui.theme.border
import com.attobot.dashboard.ui.theme.muted
import com.attobot.dashboard.ui.theme.ok
import com.attobot.dashboard.ui.theme.panel
import com.attobot.dashboard.ui.theme.pend
import com.attobot.dashboard.ui.theme.text
import com.attobot.dashboard.ui.theme.warn
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

private val ROLE_BORDER: Map<String, Color> = mapOf(
    "tool" to pend,
    "user" to accent,
    "assistant" to ok,
    "system" to warn,
)

@Composable
fun MessagesScreen(
    @Suppress("UNUSED_PARAMETER") navController: NavHostController,
    initialAgentId: String?,
) {
    val vm: MessagesViewModel = viewModel()
    LaunchedEffect(initialAgentId) {
        if (!initialAgentId.isNullOrEmpty()) vm.setAgentId(initialAgentId)
    }

    val state by vm.state.collectAsStateWithLifecycle()
    val agentId by vm.agentId.collectAsStateWithLifecycle()
    val agents by produceState(initialValue = AgentsCache.snapshot()) {
        value = AgentsCache.get()
    }
    val agent = agents.find { it.id.toString() == agentId }

    val s = state
    val refreshing = s is UiState.Ready && s.refreshing

    val title = "Messages" + when {
        agent != null -> " · ${agent.slug}"
        agentId.isNotEmpty() -> " · agent $agentId"
        else -> ""
    }

    PullRefreshScreen(refreshing = refreshing, onRefresh = vm::refresh) {
        Text(
            title,
            color = text,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 12.dp),
        )
        AgentPills(agentId, vm::setAgentId)

        when {
            agentId.isEmpty() -> EmptyState("Pick an agent above.")
            s is UiState.Loading -> LoadingView()
            s is UiState.Error -> ErrorState(s.message)
            s is UiState.Ready -> MessageStream(
                rows = s.data,
                onLoadOlder = vm::loadOlder,
                onTrace = { id -> navController.navigate(Routes.trace(id)) },
            )
        }
    }
}

@Composable
private fun MessageStream(rows: List<MessageRow>, onLoadOlder: (Long) -> Unit, onTrace: (Long) -> Unit) {
    if (rows.isEmpty()) {
        EmptyState("No messages.")
        return
    }
    val ordered = rows.asReversed() // oldest on top
    val oldest = ordered.first().id
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        ordered.forEach { MessageBubble(it, onTrace = onTrace) }
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            LoadOlderButton(onClick = { onLoadOlder(oldest) })
        }
    }
}

@Composable
private fun MessageBubble(m: MessageRow, onTrace: (Long) -> Unit) {
    val payload = m.payload
    val toolCalls = mutableListOf<JsonObject>()
    if (payload is JsonObject) {
        val tc = payload["tool_calls"]
        if (tc is JsonArray) {
            tc.forEach { if (it is JsonObject) toolCalls.add(it) }
        }
    }
    val borderColor = ROLE_BORDER[m.role] ?: border
    var payloadOpen by rememberSaveable { mutableStateOf(false) }
    // Reasoning models (o-series, deepseek-r1, qwen-thinking, …) put their
    // chain-of-thought in `reasoning_content` and leave `content` empty.
    // record_assistant flattens the raw LLM message straight into the payload,
    // so reasoning_content lives at the top level — fall back to it when the
    // visible reply is blank instead of showing an empty bubble.
    val reasoning = run {
        val rc = (payload as? JsonObject)?.get("reasoning_content")
        if (rc is JsonPrimitive && rc.isString) rc.content else ""
    }

    Surface(
        color = panel,
        border = BorderStroke(1.dp, border),
        shape = RoundedCornerShape(10.dp),
    ) {
        Row(Modifier.height(IntrinsicSize.Min)) {
            Box(
                Modifier
                    .width(3.dp)
                    .fillMaxHeight()
                    .background(borderColor),
            )
            Column(Modifier.weight(1f).padding(10.dp)) {
                // Meta row.
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        m.role.uppercase(),
                        color = text,
                        fontWeight = FontWeight.Bold,
                        fontSize = 12.sp,
                    )
                    Text("#${m.id}", color = muted, fontSize = 12.sp, modifier = Modifier.padding(start = 10.dp))
                    m.channel?.let {
                        Text(it, color = muted, fontSize = 12.sp, modifier = Modifier.padding(start = 10.dp))
                    }
                    m.toolCallId?.let {
                        Text("tc $it", color = muted, fontSize = 12.sp, modifier = Modifier.padding(start = 10.dp))
                    }
                    Text(
                        "trace",
                        color = accent,
                        fontSize = 12.sp,
                        modifier = Modifier
                            .padding(start = 10.dp)
                            .clickable { onTrace(m.id) },
                    )
                    Spacer(Modifier.weight(1f))
                    Text(timeAgo(m.createdAt), color = muted, fontSize = 12.sp)
                }

                if (m.content.isNotEmpty()) {
                    Text(
                        m.content,
                        color = text,
                        fontSize = 13.sp,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                } else if (reasoning.isNotEmpty()) {
                    Column(
                        Modifier.padding(top = 4.dp),
                        verticalArrangement = Arrangement.spacedBy(2.dp),
                    ) {
                        Text(
                            "REASONING",
                            color = accent,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                        )
                        Text(
                            reasoning,
                            color = muted,
                            fontSize = 13.sp,
                            fontStyle = FontStyle.Italic,
                        )
                    }
                }

                if (toolCalls.isNotEmpty()) {
                    Column(Modifier.padding(top = 6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        toolCalls.forEach { tc ->
                            // OpenAI shape: each call is { id, type, function: { name, arguments } },
                            // so name and arguments live one level down under `function` (mirrors
                            // the web ToolCall interface).
                            val function = tc["function"] as? JsonObject
                            Column(Modifier.padding(start = 4.dp)) {
                                Text(
                                    (function?.get("name") as? JsonPrimitive)?.content ?: "",
                                    color = accent,
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 12.sp,
                                    modifier = Modifier.padding(bottom = 2.dp),
                                )
                                JsonView(function?.get("arguments"))
                            }
                        }
                    }
                } else if (payload is JsonObject && payload.keys.isNotEmpty()) {
                    Column {
                        Text(
                            if (payloadOpen) "▾ payload" else "▸ payload",
                            color = accent,
                            fontSize = 12.sp,
                            modifier = Modifier
                                .clickable { payloadOpen = !payloadOpen }
                                .padding(vertical = 2.dp),
                        )
                        if (payloadOpen) {
                            JsonText(payload)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LoadOlderButton(onClick: () -> Unit) {
    Surface(
        color = panel,
        shape = RoundedCornerShape(6.dp),
        border = BorderStroke(1.dp, border),
        modifier = Modifier
            .padding(top = 4.dp)
            .clickable(onClick = onClick),
    ) {
        Text(
            "Load older",
            color = accent,
            fontSize = 13.sp,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
}
