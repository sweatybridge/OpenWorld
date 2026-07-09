package com.attobot.dashboard.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive

/**
 * Response shapes for the read-only `/api` endpoints. A 1:1 port of
 * dashboard/mobile/src/lib/api.ts (which itself mirrors dashboard/web/src/api.ts).
 *
 * Count fields arrive as strings (the server casts to `::text`) and bigint ids
 * as [Long]. Arbitrary JSON columns (info / result / payload / detail / value /
 * execution rows) are decoded as [JsonElement] so the UI can pretty-print them.
 *
 * `@SerialName` is applied to every snake_case JSON key for robust decoding.
 */

// ---------------- Overview ----------------

@Serializable
data class Overview(
    val metrics: Map<String, JsonElement>? = null,
    val worker: Worker? = null,
    @SerialName("by_type") val byType: List<NameTypeCount> = emptyList(),
    @SerialName("by_status") val byStatus: List<NameStatusCount> = emptyList(),
    val agents: List<OverviewAgent> = emptyList(),
)

@Serializable
data class Worker(
    @SerialName("started_at") val startedAt: String? = null,
    @SerialName("last_seen_at") val lastSeenAt: String? = null,
    @SerialName("age_seconds") val ageSeconds: Double? = null,
)

@Serializable
data class NameTypeCount(val type: String, val count: String)

@Serializable
data class NameStatusCount(val status: String, val count: String)

@Serializable
data class OverviewAgent(val id: Long, val slug: String, val enabled: Boolean)

// ---------------- Workflows ----------------

@Serializable
data class WorkflowRow(
    val id: String,
    val label: String,
    val status: String,
    @SerialName("submitted_by") val submittedBy: String,
    val db: String? = null,
    @SerialName("updated_at") val updatedAt: String,
    val type: String,
    val agent: String? = null,
)

@Serializable
data class WorkflowList(
    val rows: List<WorkflowRow> = emptyList(),
    val total: Int = 0,
    val limit: Int = 0,
    val offset: Int = 0,
)

@Serializable
data class InstanceNode(
    @SerialName("execution_id") val executionId: String,
    @SerialName("node_id") val nodeId: String,
    @SerialName("node_type") val nodeType: String,
    val query: String? = null,
    @SerialName("result_name") val resultName: String? = null,
    @SerialName("left_node") val leftNode: String? = null,
    @SerialName("right_node") val rightNode: String? = null,
    val status: String? = null,
    val result: JsonElement? = null,
)

@Serializable
data class WorkflowDetail(
    val info: Map<String, JsonElement>? = null,
    val explain: String? = null,
    val result: JsonElement? = null,
    val nodes: List<InstanceNode> = emptyList(),
    @SerialName("current_execution_id") val currentExecutionId: String? = null,
    val executions: List<Map<String, JsonElement>> = emptyList(),
)

// ---------------- Agents ----------------

@Serializable
data class AgentRow(
    val id: Long,
    val slug: String,
    val soul: String,
    val enabled: Boolean,
    @SerialName("max_turn") val maxTurn: Int,
    @SerialName("model_id") val modelId: Int,
    @SerialName("model_name") val modelName: String? = null,
    @SerialName("api_base") val apiBase: String? = null,
    val temperature: String? = null,
    @SerialName("reasoning_effort") val reasoningEffort: String? = null,
    @SerialName("context_tokens") val contextTokens: Int? = null,
    @SerialName("multimodal_support") val multimodalSupport: Boolean? = null,
    @SerialName("created_at") val createdAt: String,
    @SerialName("updated_at") val updatedAt: String,
    @SerialName("msg_count") val msgCount: String,
    @SerialName("mem_count") val memCount: String,
    @SerialName("wf_count") val wfCount: String,
)

// ---------------- Messages ----------------

@Serializable
data class MessageRow(
    val id: Long,
    @SerialName("agent_id") val agentId: Long,
    val role: String,
    val content: String,
    val payload: JsonElement? = null,
    val channel: String? = null,
    @SerialName("chat_id") val chatId: String? = null,
    @SerialName("tool_call_id") val toolCallId: String? = null,
    @SerialName("created_at") val createdAt: String,
)

// ---------------- Memory / Users / Lifecycle / Config / Blobs ----------------

@Serializable
data class MemoryRow(
    val id: Long,
    @SerialName("agent_id") val agentId: Long,
    val content: String? = null,
    val payload: JsonElement? = null,
    val enabled: Boolean? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    @SerialName("source_message_ids") val sourceMessageIds: List<Long>? = null,
)

@Serializable
data class UserRow(
    val id: Long,
    val channel: String? = null,
    @SerialName("external_id") val externalId: String? = null,
    val username: String? = null,
    @SerialName("display_name") val displayName: String? = null,
    val tier: String? = null,
    val payload: JsonElement? = null,
    @SerialName("created_at") val createdAt: String? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
)

@Serializable
data class LifecycleRow(
    val id: Long,
    @SerialName("agent_id") val agentId: Long? = null,
    val event: String? = null,
    val detail: JsonElement? = null,
    @SerialName("created_at") val createdAt: String? = null,
)

@Serializable
data class ConfigRow(
    @SerialName("agent_id") val agentId: Long,
    val key: String,
    val value: JsonElement? = null,
    val secret: Boolean,
    @SerialName("updated_at") val updatedAt: String? = null,
)

@Serializable
data class BlobRow(
    @SerialName("agent_id") val agentId: Long? = null,
    val hash: String? = null,
    val size: Long? = null,
    @SerialName("created_at") val createdAt: String? = null,
)

// ---------------- Response wrappers ----------------

@Serializable
data class AgentsResponse(val rows: List<AgentRow> = emptyList())

@Serializable
data class MessagesResponse(val rows: List<MessageRow> = emptyList())

@Serializable
data class MemoryResponse(val rows: List<MemoryRow> = emptyList())

@Serializable
data class UsersResponse(val rows: List<UserRow> = emptyList())

@Serializable
data class LifecycleResponse(val rows: List<LifecycleRow> = emptyList())

@Serializable
data class ConfigResponse(val rows: List<ConfigRow> = emptyList())

@Serializable
data class BlobsResponse(val rows: List<BlobRow> = emptyList())

// ---------------- Arbitrary-JSON helpers ----------------

/**
 * Reads a value from an arbitrary-JSON row (e.g. an execution row or an info
 * map). Returns null when the key is absent or the value is JSON null. For
 * primitives this is the raw content string (numbers/bools come back as their
 * textual form, mirroring the TS `String(r.field)` access).
 *
 * Named `field` (not `text`) so it never collides with the `text` theme colour.
 */
fun Map<String, JsonElement>.field(key: String): String? {
    val element = this[key] ?: return null
    if (element is JsonNull) return null
    return (element as? JsonPrimitive)?.content
}

/** Same as [field] but with a fallback when missing/null. */
fun Map<String, JsonElement>.fieldOr(key: String, fallback: String): String =
    field(key) ?: fallback
