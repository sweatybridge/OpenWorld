package com.OpenWorld.dashboard.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.BorderStroke
import androidx.compose.material3.Text
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.OpenWorld.dashboard.ui.theme.err
import com.OpenWorld.dashboard.ui.theme.muted

/** Centred spinner + "Loading…" — the analogue of the RN <Spinner/>. */
@Composable
fun LoadingView(modifier: Modifier = Modifier) {
    Box(
        modifier
            .fillMaxWidth()
            .padding(vertical = 32.dp),
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            CircularProgressIndicator(color = com.OpenWorld.dashboard.ui.theme.accent)
            Text("Loading…", color = muted, fontSize = 13.sp, modifier = Modifier.padding(top = 8.dp))
        }
    }
}

/** Centred muted text for empty lists/cards. */
@Composable
fun EmptyState(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        color = muted,
        fontSize = 13.sp,
        textAlign = TextAlign.Center,
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = 24.dp),
    )
}

/** Red-tinted error box mirroring the RN <ErrorState/>. */
@Composable
fun ErrorState(message: String, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().padding(top = 8.dp)) {
        Surface(
            color = err.copy(alpha = 0.12f),
            border = BorderStroke(1.dp, err),
            shape = RoundedCornerShape(8.dp),
        ) {
            Text(
                "⚠️ $message",
                color = err,
                fontSize = 13.sp,
                modifier = Modifier.padding(12.dp),
            )
        }
    }
}
