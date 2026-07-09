package com.attobot.dashboard

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.attobot.dashboard.ui.nav.Root
import com.attobot.dashboard.ui.theme.AttobotTheme

/**
 * Single activity. The whole UI is Compose — the auth gate (Root) decides
 * between the Setup / BackendDown / main dashboard shells.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            AttobotTheme {
                Root()
            }
        }
    }
}
