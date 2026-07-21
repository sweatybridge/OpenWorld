package com.attobot.dashboard.core

import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Pure formatting helpers — a port of dashboard/mobile/src/lib/format.ts
 * (itself a verbatim copy of dashboard/web/src/format.ts). Same thresholds and
 * fallbacks so cells render identically to the web / RN clients.
 */

/** "just now" / "Ns ago" / "Nm ago" / "Nh ago" / "Nd ago"; null/blank → "—". */
fun timeAgo(iso: String?): String {
    if (iso.isNullOrBlank()) return "—"
    val t = parseIsoMillis(iso) ?: return iso
    val s = ((System.currentTimeMillis() - t) / 1000).coerceAtLeast(0)
    return when {
        s < 5 -> "just now"
        s < 60 -> "${s}s ago"
        s < 3600 -> "${s / 60}m ago"
        s < 86400 -> "${s / 3600}h ago"
        else -> "${s / 86400}d ago"
    }
}

/** Localized date-time; null → "—"; parse-failure → the raw string. */
fun formatDateTime(iso: String?): String {
    if (iso.isNullOrBlank()) return "—"
    val t = parseIsoMillis(iso) ?: return iso
    val ldt = LocalDateTime.ofInstant(Instant.ofEpochMilli(t), ZoneId.systemDefault())
    return ldt.format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM))
}

/** "<1024 N B" / "N.N KB|MB|GB|TB" (0 decimals once ≥100); null/non-numeric → "—". */
fun formatBytes(n: Long?): String {
    if (n == null) return "—"
    if (n < 1024) return "$n B"
    val units = arrayOf("KB", "MB", "GB", "TB")
    var v = n / 1024.0
    var i = 0
    while (v >= 1024.0 && i < units.size - 1) {
        v /= 1024.0
        i++
    }
    val formatted = if (v >= 100.0) "%.0f".format(v) else "%.1f".format(v)
    return "$formatted ${units[i]}"
}

/** "<1000 N ms" / "N.N s"; null → "—". */
fun formatMs(ms: Double?): String {
    if (ms == null) return "—"
    if (ms < 1000.0) return "${ms.toLong()} ms"
    return "%.1f s".format(ms / 1000.0)
}

/** A duration in seconds (e.g. an HLS playlist's total runtime); null/<=0 → "—". */
fun formatDuration(seconds: Double?): String {
    if (seconds == null || seconds.isNaN() || seconds <= 0.0) return "—"
    if (seconds < 60.0) {
        val decimals = if (seconds < 10.0) 1 else 0
        return "%.${decimals}f s".format(seconds)
    }
    val whole = seconds.toLong()
    val m = (whole / 60).toInt()
    val s = (whole % 60).toInt()
    if (m < 60) return "${m}m ${s}s"
    val h = m / 60
    return "${h}h ${m % 60}m"
}

/** Collapse whitespace, trim and clip to [n] chars with an ellipsis. */
fun truncate(s: String?, n: Int = 100): String {
    if (s.isNullOrBlank()) return ""
    val one = s.replace(Regex("\\s+"), " ").trim()
    return if (one.length > n) one.take(n) + "…" else one
}

/**
 * Lenient ISO-8601 parser (Postgres `timestamptz` strings, possibly with a
 * space separator or no colon in the offset). Returns epoch millis or null.
 */
private fun parseIsoMillis(iso: String): Long? {
    // Normalise a space "T" separator so Instant/OffsetDateTime accept it.
    val normalized = iso.replace(' ', 'T')
    return try {
        Instant.parse(normalized).toEpochMilli()
    } catch (e: Exception) {
        tryOrNull { OffsetDateTime.parse(normalized).toInstant().toEpochMilli() }
            ?: tryOrNull { LocalDateTime.parse(normalized).toInstant(ZoneOffset.UTC).toEpochMilli() }
    }
}

private inline fun <T> tryOrNull(block: () -> T): T? = try {
    block()
} catch (e: Exception) {
    null
}
