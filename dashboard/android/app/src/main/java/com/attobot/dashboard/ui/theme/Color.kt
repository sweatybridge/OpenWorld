package com.attobot.dashboard.ui.theme

import androidx.compose.ui.graphics.Color

/**
 * Visual palette — mirrored from the web dashboard (dashboard/web/src/styles.css
 * :root) via dashboard/mobile/src/lib/theme.ts. Same hex values so the Android
 * client reads as the same product.
 */

val bg = Color(0xFF0F1115)
val panel = Color(0xFF171A21)
val panel2 = Color(0xFF1E222B)
val border = Color(0xFF2A2F3A)
val text = Color(0xFFE6E8EC)
val muted = Color(0xFF9AA3B2)
val accent = Color(0xFF4F9CF9)
val ok = Color(0xFF3FB950)
val warn = Color(0xFFD29922)
val err = Color(0xFFF85149)
val run = Color(0xFF4F9CF9)
val pend = Color(0xFF8B949E)
val cancel = Color(0xFFDB6D28)

private val STATUS_COLOR: Map<String, Color> = mapOf(
    "completed" to ok,
    "failed" to err,
    "running" to run,
    "pending" to pend,
    "cancelled" to cancel,
    "cancelled_" to cancel,
    "unknown" to pend,
)

/** status string -> colour, mirroring the web `.st-*` classes. Unknown → pend. */
fun statusColor(status: String?): Color =
    STATUS_COLOR[status?.toString() ?: "unknown"] ?: pend
