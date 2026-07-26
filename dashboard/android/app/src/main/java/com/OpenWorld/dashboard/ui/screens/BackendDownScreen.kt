package com.OpenWorld.dashboard.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.OpenWorld.dashboard.ui.theme.accent
import com.OpenWorld.dashboard.ui.theme.bg
import com.OpenWorld.dashboard.ui.theme.border
import com.OpenWorld.dashboard.ui.theme.err
import com.OpenWorld.dashboard.ui.theme.muted
import com.OpenWorld.dashboard.ui.theme.panel
import com.OpenWorld.dashboard.ui.theme.text

/** Shown when the gate probe fails for a non-auth reason (host unreachable). */
@Composable
fun BackendDownScreen(
    message: String,
    serverUrl: String,
    onRetry: () -> Unit,
    onEdit: () -> Unit,
) {
    Box(
        Modifier
            .fillMaxSize()
            .background(bg)
            .statusBarsPadding()
            .padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        Surface(
            color = panel,
            border = BorderStroke(1.dp, border),
            shape = RoundedCornerShape(12.dp),
            modifier = Modifier
                .fillMaxWidth()
                .width(IntrinsicSize.Max),
        ) {
            Column(Modifier.padding(20.dp)) {
                Text(
                    "⚠️ Cannot reach backend",
                    color = err,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(bottom = 8.dp),
                )
                Text(
                    serverUrl.ifBlank { "(no server set)" },
                    color = text,
                    fontFamily = FontFamily.Monospace,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(bottom = 8.dp),
                )
                Text(
                    message,
                    color = muted,
                    fontSize = 13.sp,
                    modifier = Modifier.padding(bottom = 18.dp),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Button(
                        onClick = onRetry,
                        colors = ButtonDefaults.buttonColors(containerColor = accent),
                    ) { Text("Retry", color = text, fontWeight = FontWeight.SemiBold) }
                    OutlinedButton(onClick = onEdit) { Text("Edit server", color = text) }
                }
            }
        }
    }
}
