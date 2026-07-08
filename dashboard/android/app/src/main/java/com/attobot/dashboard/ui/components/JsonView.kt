package com.attobot.dashboard.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import com.attobot.dashboard.ui.theme.accent
import com.attobot.dashboard.ui.theme.border
import com.attobot.dashboard.ui.theme.panel2
import com.attobot.dashboard.ui.theme.text

private val prettyJson = Json { prettyPrint = true }
private val parseJson = Json { ignoreUnknownKeys = true; isLenient = true }

/**
 * Port of the web/RN JsonView: a single toggle that pretty-prints the value.
 * Many pg results come back as a JSON *string*, so parse-and-restringify when we
 * can; on failure show the raw string.
 */
@Composable
fun JsonView(value: JsonElement?, defaultOpen: Boolean = false) {
    var open by rememberSaveable { mutableStateOf(defaultOpen) }
    val rendered = remember(value) {
        when {
            value == null -> "null"
            value is JsonPrimitive && value.isString -> {
                val content = value.content
                try {
                    prettyJson.encodeToString(JsonElement.serializer(), parseJson.parseToJsonElement(content))
                } catch (e: Exception) {
                    content
                }
            }
            value is JsonNull -> "null"
            else -> prettyJson.encodeToString(JsonElement.serializer(), value)
        }
    }
    Column {
        Text(
            if (open) "▾ hide" else "▸ show",
            color = accent,
            fontSize = 13.sp,
            modifier = Modifier
                .clickable { open = !open }
                .padding(vertical = 2.dp),
        )
        if (open) {
            Surface(
                color = panel2,
                border = BorderStroke(1.dp, border),
                shape = RoundedCornerShape(6.dp),
                modifier = Modifier.padding(vertical = 6.dp),
            ) {
                Box(
                    Modifier
                        .horizontalScroll(rememberScrollState())
                        .padding(10.dp),
                ) {
                    Text(
                        rendered,
                        color = text,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp,
                    )
                }
            }
        }
    }
}
