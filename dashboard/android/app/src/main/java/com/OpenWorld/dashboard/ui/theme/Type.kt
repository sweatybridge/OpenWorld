package com.OpenWorld.dashboard.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** Minimal typography tuned to the dashboard's compact, data-dense cells. */
val AppTypography = Typography(
    titleLarge = TextStyle(
        fontWeight = FontWeight.Bold,
        fontSize = 20.sp,
        color = text,
    ),
    bodyLarge = TextStyle(
        fontSize = 13.sp,
        color = text,
    ),
    bodyMedium = TextStyle(
        fontSize = 13.sp,
        color = text,
    ),
    bodySmall = TextStyle(
        fontSize = 12.sp,
        color = muted,
    ),
    labelSmall = TextStyle(
        fontSize = 12.sp,
        color = text,
    ),
)

/** Monospace style helper for ids / hashes / SQL fragments. */
val monoStyle = TextStyle(
    fontFamily = FontFamily.Monospace,
    fontSize = 12.sp,
    color = accent,
)

val monoBody = TextStyle(
    fontFamily = FontFamily.Monospace,
    fontSize = 12.sp,
    color = text,
)
