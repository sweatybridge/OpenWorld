package com.attobot.dashboard.ui.components

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.attobot.dashboard.ui.theme.muted

/** Label/value list — the mobile analogue of the web `.kv` `<dl>`. */
@Composable
fun KeyValue(items: List<Pair<String, @Composable () -> Unit>>) {
    Column {
        items.forEachIndexed { i, (key, value) ->
            Row(Modifier.fillMaxWidth().padding(vertical = 3.dp)) {
                Text(key, color = muted, fontSize = 13.sp, modifier = Modifier.width(120.dp))
                Box(Modifier.weight(1f)) { value() }
            }
        }
    }
}
