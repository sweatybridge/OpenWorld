package com.OpenWorld.dashboard.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.OpenWorld.dashboard.state.Reason
import com.OpenWorld.dashboard.ui.theme.accent
import com.OpenWorld.dashboard.ui.theme.bg
import com.OpenWorld.dashboard.ui.theme.border
import com.OpenWorld.dashboard.ui.theme.err
import com.OpenWorld.dashboard.ui.theme.muted
import com.OpenWorld.dashboard.ui.theme.panel
import com.OpenWorld.dashboard.ui.theme.text

private val HTTP_RE = Regex("^https?://", RegexOption.IGNORE_CASE)

/**
 * First-run / token / edit-server gate — the Android counterpart of the RN
 * <SetupScreen/>. A phone can't reach the dev box's loopback, so the user points
 * the app at a reachable host (LAN IP / Tailscale) and optionally supplies the
 * bearer token.
 */
@Composable
fun SetupScreen(
    reason: Reason,
    initialBase: String,
    initialToken: String,
    onCancel: (() -> Unit)?,
    onSave: (base: String, token: String) -> Unit,
) {
    var base by rememberSaveable { mutableStateOf(initialBase) }
    var token by rememberSaveable { mutableStateOf(initialToken) }
    var error by remember { mutableStateOf<String?>(null) }

    val title = when (reason) {
        Reason.FirstRun -> "Connect to dashboard"
        Reason.Token -> "Token required"
        Reason.Edit -> "Edit server"
    }
    val subtitle = if (reason == Reason.Token) {
        "The server requires a bearer token (got 401)."
    } else {
        "Point the app at a reachable dashboard host."
    }

    val save = {
        val b = base.trim()
        error = when {
            b.isEmpty() -> "Server URL is required."
            !HTTP_RE.containsMatchIn(b) -> "Server URL must start with http:// or https://"
            else -> null
        }
        if (error == null) {
            onSave(b, token.trim())
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(bg)
            .statusBarsPadding()
            .imePadding(),
        contentAlignment = Alignment.Center,
    ) {
        Surface(
            color = panel,
            border = BorderStroke(1.dp, border),
            shape = RoundedCornerShape(12.dp),
            modifier = Modifier
                .fillMaxWidth()
                .padding(24.dp),
        ) {
            Column(
                Modifier
                    .verticalScroll(rememberScrollState())
                    .padding(20.dp),
            ) {
                Text(
                    "OpenWorld · dashboard",
                    color = muted,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(bottom = 6.dp),
                )
                Text(
                    title,
                    color = text,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(bottom = 4.dp),
                )
                Text(subtitle, color = muted, fontSize = 13.sp)

                FieldLabel("Server URL")
                OpenWorldField(
                    value = base,
                    onValueChange = { base = it },
                    placeholder = "http://192.168.1.10:8088",
                    keyboardType = KeyboardType.Uri,
                )

                FieldLabel("Bearer token (optional)")
                OpenWorldField(
                    value = token,
                    onValueChange = { token = it },
                    placeholder = "leave blank if the server has no token",
                    keyboardType = KeyboardType.Password,
                    obscure = true,
                )

                error?.let {
                    Text(
                        it,
                        color = err,
                        fontSize = 12.sp,
                        modifier = Modifier.padding(top = 10.dp),
                    )
                }

                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(top = 18.dp),
                    horizontalArrangement = Arrangement.End,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (onCancel != null) {
                        OutlinedButton(
                            onClick = onCancel,
                            modifier = Modifier.padding(end = 10.dp),
                        ) { Text("Cancel", color = text) }
                    }
                    Button(
                        onClick = save,
                        colors = ButtonDefaults.buttonColors(containerColor = accent),
                    ) { Text("Save", color = text, fontWeight = FontWeight.SemiBold) }
                }

                Text(
                    "The dashboard runs on the host's loopback by default (127.0.0.1:8088), " +
                        "so reach it via the host's LAN IP or a Tailscale address. The token is " +
                        "stored in the Android keystore and sent as Authorization: Bearer.",
                    color = muted,
                    fontSize = 11.sp,
                    lineHeight = 17.sp,
                    modifier = Modifier.padding(top = 16.dp),
                )
            }
        }
    }
}

@Composable
private fun FieldLabel(label: String) {
    Text(
        label,
        color = muted,
        fontSize = 12.sp,
        modifier = Modifier.padding(top = 12.dp, bottom = 6.dp),
    )
}

@Composable
private fun OpenWorldField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    keyboardType: KeyboardType = KeyboardType.Text,
    obscure: Boolean = false,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
        placeholder = { Text(placeholder, color = muted) },
        textStyle = androidx.compose.ui.text.TextStyle(color = text, fontSize = 14.sp),
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        visualTransformation = if (obscure) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        shape = RoundedCornerShape(8.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = text,
            unfocusedTextColor = text,
            focusedContainerColor = bg,
            unfocusedContainerColor = bg,
            focusedBorderColor = accent,
            unfocusedBorderColor = border,
            cursorColor = accent,
            focusedPlaceholderColor = muted,
            unfocusedPlaceholderColor = muted,
        ),
    )
}
