package com.attobot.dashboard.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.attobot.dashboard.ui.theme.border
import com.attobot.dashboard.ui.theme.muted
import com.attobot.dashboard.ui.theme.panel
import com.attobot.dashboard.ui.theme.panel2

/**
 * Panel card with an optional uppercase header row. Mirrors the RN <Card/>:
 * panel surface, 1dp border, 10dp radius, 14dp body padding, 16dp bottom margin.
 */
@Composable
fun AttobotCard(
    title: String? = null,
    modifier: Modifier = Modifier,
    right: (@Composable () -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    Surface(
        color = panel,
        border = androidx.compose.foundation.BorderStroke(1.dp, border),
        shape = RoundedCornerShape(10.dp),
        modifier = modifier
            .fillMaxWidth()
            .padding(bottom = 16.dp),
    ) {
        Column {
            if (title != null || right != null) {
                Surface(color = panel2) {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        if (title != null) {
                            Text(
                                title.uppercase(),
                                color = muted,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Medium,
                                letterSpacing = 0.4.sp,
                            )
                        } else {
                            Box {}
                        }
                        right?.invoke()
                    }
                }
                HorizontalDivider(color = border)
            }
            Box(Modifier.padding(14.dp)) { content() }
        }
    }
}
