package com.attobot.dashboard.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.attobot.dashboard.core.Credentials
import com.attobot.dashboard.state.GateViewModel
import com.attobot.dashboard.ui.components.AttobotCard
import com.attobot.dashboard.ui.components.KeyValue
import com.attobot.dashboard.ui.components.PullRefreshScreen
import com.attobot.dashboard.ui.theme.border
import com.attobot.dashboard.ui.theme.err
import com.attobot.dashboard.ui.theme.muted
import com.attobot.dashboard.ui.theme.panel
import com.attobot.dashboard.ui.theme.text

/** Connection settings + token management (drawer → Settings). */
@Composable
fun SettingsScreen(gateVM: GateViewModel) {
    PullRefreshScreen(refreshing = false, onRefresh = null) {
        Text(
            "Settings",
            color = text,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 12.dp),
        )

        AttobotCard(title = "Connection") {
            KeyValue(
                items = listOf(
                    "server" to {
                        Text(
                            Credentials.currentBaseUrl.ifBlank { "(not set)" },
                            color = text,
                            fontFamily = FontFamily.Monospace,
                            fontSize = 12.sp,
                        )
                    },
                    "token" to {
                        val set = Credentials.currentToken().isNotEmpty()
                        Text(
                            if (set) "set (stored in keystore)" else "not set",
                            color = text,
                            fontSize = 13.sp,
                        )
                    },
                ),
            )
        }

        SettingsButton("Edit server / token", danger = false, onClick = gateVM::edit)
        SettingsButton("Clear token", danger = true, onClick = gateVM::clearToken)

        Text(
            "attobot dashboard · read-only native client for Android. " +
                "Same GET /api/* endpoints as the web console; secrets stay masked server-side.",
            color = muted,
            fontSize = 11.sp,
            lineHeight = 16.sp,
            modifier = Modifier.padding(top = 8.dp),
        )
    }
}

@Composable
private fun SettingsButton(label: String, danger: Boolean, onClick: () -> Unit) {
    Surface(
        color = panel,
        shape = RoundedCornerShape(8.dp),
        border = BorderStroke(1.dp, if (danger) err else border),
        modifier = Modifier
            .fillMaxWidth()
            .padding(bottom = 10.dp)
            .clickable(onClick = onClick),
    ) {
        Text(
            label,
            color = text,
            fontWeight = FontWeight.SemiBold,
            fontSize = 14.sp,
            modifier = Modifier.padding(vertical = 12.dp).then(
                Modifier.fillMaxWidth(),
            ),
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        )
    }
}
