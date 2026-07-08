package com.attobot.dashboard.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable

/**
 * The dashboard is dark-only. A single Material3 [darkColorScheme] maps the web
 * palette onto surface/primary/etc. so Material3 components (PullToRefreshBox,
 * Scaffold, TopAppBar) inherit the right colours automatically.
 */
private val AttobotColors = darkColorScheme(
    primary = accent,
    onPrimary = text,
    background = bg,
    onBackground = text,
    surface = panel,
    onSurface = text,
    surfaceVariant = panel2,
    onSurfaceVariant = muted,
    secondary = accent,
    onSecondary = text,
    tertiary = accent,
    error = err,
    onError = text,
    outline = border,
    outlineVariant = border,
)

@Composable
fun AttobotTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = AttobotColors,
        typography = AppTypography,
        content = content,
    )
}
