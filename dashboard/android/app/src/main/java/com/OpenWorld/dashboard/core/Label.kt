package com.OpenWorld.dashboard.core

/**
 * Verbatim port of dashboard/mobile/src/lib/label.ts — parses ow:* durable
 * instance labels into a friendly type + context. Currently unused by the port's
 * UI (the RN screens show the raw `type` field directly) but kept for parity.
 */

enum class LabelType {
    loop, inbox, cron, send, tool, typing, ow, other
}

data class ParsedLabel(
    val type: LabelType,
    val agent: String?,
    val ref: String?,
    val friendly: String,
)

private val LABEL_ICON = mapOf(
    LabelType.loop to "🔁",
    LabelType.inbox to "📥",
    LabelType.cron to "⏰",
    LabelType.send to "📤",
    LabelType.tool to "🔧",
    LabelType.typing to "⌨️",
    LabelType.ow to "🤖",
    LabelType.other to "•",
)

private val LABEL_TEXT = mapOf(
    LabelType.loop to "agent loop",
    LabelType.inbox to "telegram inbox",
    LabelType.cron to "cron",
    LabelType.send to "telegram send",
    LabelType.tool to "tool call",
    LabelType.typing to "typing",
    LabelType.ow to "ow",
    LabelType.other to "workflow",
)

fun labelIcon(type: String): String =
    runCatching { LABEL_ICON[LabelType.valueOf(type)] }.getOrNull() ?: LABEL_ICON.getValue(LabelType.other)

fun parseLabel(raw: String): ParsedLabel {
    val parts = raw.split(":")
    if (parts.firstOrNull() != "ow" || parts.size < 2) {
        return ParsedLabel(LabelType.other, null, null, raw)
    }
    // ow:<agent>:inbox
    if (parts.size == 3 && parts[2] == "inbox") {
        return ParsedLabel(LabelType.inbox, parts[1], null, "${parts[1]} ${LABEL_TEXT.getValue(LabelType.inbox)}")
    }
    // ow:<agent>:loop  OR  ow:<agent>:loop:<msg_id>
    if (parts.size >= 3 && parts[2] == "loop") {
        val ref = if (parts.size >= 4) parts[3] else null
        val suffix = ref?.let { " · msg #$it" } ?: ""
        return ParsedLabel(LabelType.loop, parts[1], ref, "${parts[1]} ${LABEL_TEXT.getValue(LabelType.loop)}$suffix")
    }
    // ow:<agent>:cron:<name>
    if (parts.size >= 4 && parts[2] == "cron") {
        val name = parts.subList(3, parts.size).joinToString(":")
        return ParsedLabel(LabelType.cron, parts[1], name, "${parts[1]} cron \"$name\"")
    }
    // ow:send:<id>
    if (parts[1] == "send" && parts.size >= 3) {
        return ParsedLabel(LabelType.send, null, parts[2], "send msg #${parts[2]}")
    }
    // ow:typing:<id>
    if (parts[1] == "typing" && parts.size >= 3) {
        return ParsedLabel(LabelType.typing, null, parts[2], "typing #${parts[2]}")
    }
    // ow:tool:<msg>:<tc>
    if (parts[1] == "tool" && parts.size >= 4) {
        return ParsedLabel(LabelType.tool, null, parts.subList(2, parts.size).joinToString(":"), "tool msg #${parts[2]}")
    }
    return ParsedLabel(LabelType.ow, null, null, raw)
}

/**
 * Numeric message id embedded in a traceable label (loop/send/typing/tool), or
 * null. Mirrors ow.parse_instance_label on the server; used to open the
 * turn-trace view from any of these instances.
 */
fun messageIdFromLabel(raw: String): Long? {
    val match = Regex("ow:(?:[^:]+:loop|send|tool|typing):(\\d+)").find(raw) ?: return null
    return match.groupValues[1].toLongOrNull()
}
