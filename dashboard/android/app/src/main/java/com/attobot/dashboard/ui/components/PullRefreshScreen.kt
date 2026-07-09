package com.attobot.dashboard.ui.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Screen-level vertical scroller with optional Material3 pull-to-refresh. The
 * Android analogue of the RN <Scroll/> (RefreshControl on Android). Every list
 * page composes its content inside this.
 *
 * Pass [onRefresh] = null for screens that aren't refreshable (Agents, Users).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PullRefreshScreen(
    refreshing: Boolean,
    onRefresh: (() -> Unit)?,
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    val scrollState = rememberScrollState()
    val scrollModifier = Modifier
        .fillMaxSize()
        .verticalScroll(scrollState)
        .padding(16.dp)
        .padding(bottom = 32.dp)

    if (onRefresh != null) {
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = onRefresh,
            modifier = modifier.fillMaxSize(),
        ) {
            Column(modifier = scrollModifier, content = content)
        }
    } else {
        Column(modifier = modifier.fillMaxSize().then(scrollModifier), content = content)
    }
}
