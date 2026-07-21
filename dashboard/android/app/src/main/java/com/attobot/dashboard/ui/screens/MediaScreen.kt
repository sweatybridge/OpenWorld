package com.attobot.dashboard.ui.screens

import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import coil.compose.AsyncImage
import com.attobot.dashboard.core.ApiProvider
import com.attobot.dashboard.core.MediaRow
import com.attobot.dashboard.core.formatBytes
import com.attobot.dashboard.core.formatDuration
import com.attobot.dashboard.state.MediaViewModel
import com.attobot.dashboard.state.UiState
import com.attobot.dashboard.ui.components.DataTable
import com.attobot.dashboard.ui.components.ErrorState
import com.attobot.dashboard.ui.components.LoadingView
import com.attobot.dashboard.ui.components.PullRefreshScreen
import com.attobot.dashboard.ui.components.TableColumn
import com.attobot.dashboard.ui.theme.muted
import com.attobot.dashboard.ui.theme.text

/**
 * ffmpeg.hls_playlists: media the agent ingested via `ffmpeg.hls` (in the SQL
 * tool) and may have sent with send_photo/send_video/send_audio. Each row's
 * thumbnail is computed on demand (server-side, from the first segment) and
 * loaded by Coil through the shared authed OkHttp client. No poll; mirrors the
 * web Media page.
 */
@Composable
fun MediaScreen(@Suppress("UNUSED_PARAMETER") navController: NavHostController) {
    val vm: MediaViewModel = viewModel()
    val state by vm.state.collectAsStateWithLifecycle()
    val s = state

    val rows = (s as? UiState.Ready)?.data ?: emptyList()

    PullRefreshScreen(refreshing = false, onRefresh = null) {
        Text(
            "Media",
            color = text,
            fontSize = 20.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(bottom = 12.dp),
        )
        Text(
            "${rows.size} playlist${if (rows.size == 1) "" else "s"}",
            color = muted,
            fontSize = 12.sp,
            modifier = Modifier.padding(bottom = 12.dp),
        )
        when (s) {
            is UiState.Loading -> LoadingView()
            is UiState.Error -> ErrorState(s.message)
            is UiState.Ready -> DataTable(rows = rows, columns = mediaColumns())
        }
    }
}

private fun mediaColumns(): List<TableColumn<MediaRow>> = listOf(
    TableColumn(header = "", width = 100.dp) {
        AsyncImage(
            model = ApiProvider.mediaThumbnailUrl(it.id),
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.size(72.dp).clip(RoundedCornerShape(6.dp)),
        )
    },
    TableColumn(header = "id", width = 70.dp) {
        Text(it.id, color = text, fontFamily = FontFamily.Monospace, fontSize = 12.sp, maxLines = 1)
    },
    TableColumn(header = "segments", width = 90.dp) {
        Text(it.segmentCount, color = text, fontSize = 13.sp)
    },
    TableColumn(header = "duration", width = 90.dp) {
        Text(formatDuration(it.totalDuration), color = text, fontSize = 13.sp)
    },
    TableColumn(header = "size", width = 90.dp) {
        Text(formatBytes(it.totalSize.toLongOrNull()), color = text, fontSize = 13.sp)
    },
    TableColumn(header = "target", width = 70.dp) {
        Text("${it.targetDuration}s", color = muted, fontSize = 13.sp)
    },
)
