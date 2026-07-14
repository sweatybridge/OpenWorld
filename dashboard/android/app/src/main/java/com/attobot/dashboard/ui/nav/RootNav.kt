package com.attobot.dashboard.ui.nav

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.attobot.dashboard.core.Credentials
import com.attobot.dashboard.state.GatePhase
import com.attobot.dashboard.state.GateViewModel
import com.attobot.dashboard.state.Reason
import com.attobot.dashboard.ui.screens.AgentsScreen
import com.attobot.dashboard.ui.screens.BackendDownScreen
import com.attobot.dashboard.ui.screens.BlobsScreen
import com.attobot.dashboard.ui.screens.ConfigScreen
import com.attobot.dashboard.ui.screens.MemoryScreen
import com.attobot.dashboard.ui.screens.MessagesScreen
import com.attobot.dashboard.ui.screens.OverviewScreen
import com.attobot.dashboard.ui.screens.SettingsScreen
import com.attobot.dashboard.ui.screens.SetupScreen
import com.attobot.dashboard.ui.screens.Splash
import com.attobot.dashboard.ui.screens.TraceScreen
import com.attobot.dashboard.ui.screens.UsersScreen
import com.attobot.dashboard.ui.screens.WorkflowDetailScreen
import com.attobot.dashboard.ui.screens.WorkflowsScreen
import com.attobot.dashboard.ui.theme.bg
import com.attobot.dashboard.ui.theme.border
import com.attobot.dashboard.ui.theme.muted
import com.attobot.dashboard.ui.theme.panel
import com.attobot.dashboard.ui.theme.panel2
import com.attobot.dashboard.ui.theme.text
import kotlinx.coroutines.launch

/**
 * Root of the UI. Decides what to render from the [GateViewModel] phase — the
 * Android counterpart of the RN `RootNav` gate.
 */
@Composable
fun Root() {
    val gateVM: GateViewModel = viewModel()
    val phase by gateVM.phase.collectAsStateWithLifecycle()
    when (val p = phase) {
        GatePhase.Loading -> Splash()
        is GatePhase.NeedSetup -> SetupScreen(
            reason = p.reason,
            initialBase = Credentials.currentBaseUrl,
            initialToken = if (p.reason == Reason.Token) "" else Credentials.currentToken(),
            onCancel = if (Credentials.hasBaseUrl() && p.reason != Reason.Token) gateVM::cancelEdit else null,
            onSave = gateVM::save,
        )
        is GatePhase.BackendDown -> BackendDownScreen(
            message = p.message,
            serverUrl = Credentials.currentBaseUrl,
            onRetry = gateVM::reload,
            onEdit = gateVM::edit,
        )
        GatePhase.Ready -> AppRoot(gateVM)
    }
}

@Composable
private fun AppRoot(gateVM: GateViewModel) {
    val drawerState = rememberDrawerState(initialValue = DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val navController = rememberNavController()

    val currentEntry by navController.currentBackStackEntryAsState()
    val currentRoute = currentEntry?.destination?.route
    val title = titleForRoute(currentRoute)

    val openDrawer: () -> Unit = { scope.launch { drawerState.open() } }

    ModalNavigationDrawer(
        drawerState = drawerState,
        drawerContent = {
            DrawerSheetContent(
                currentRoute = currentRoute,
                onNavigate = { route ->
                    scope.launch { drawerState.close() }
                    navController.navigateTopLevel(route)
                },
                onSettings = {
                    scope.launch { drawerState.close() }
                    navController.navigate(Routes.SETTINGS)
                },
                onClearToken = {
                    scope.launch { drawerState.close() }
                    gateVM.clearToken()
                },
            )
        },
    ) {
        Scaffold(
            topBar = { AttobotTopBar(title = title, onMenu = openDrawer) },
            containerColor = bg,
        ) { padding ->
            NavHost(
                navController = navController,
                startDestination = Routes.OVERVIEW,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
            ) {
                composable(Routes.OVERVIEW) { OverviewScreen(navController) }
                composable(
                    Routes.WORKFLOWS,
                    arguments = listOf(
                        navArgument("status") { type = NavType.StringType; nullable = true; defaultValue = null },
                        navArgument("type") { type = NavType.StringType; nullable = true; defaultValue = null },
                        navArgument("agent") { type = NavType.StringType; nullable = true; defaultValue = null },
                    ),
                ) { entry ->
                    val a = entry.arguments
                    WorkflowsScreen(
                        navController = navController,
                        status = a?.getString("status"),
                        type = a?.getString("type"),
                        agent = a?.getString("agent"),
                    )
                }
                composable(Routes.AGENTS) { AgentsScreen(navController) }
                composable(
                    Routes.MESSAGES,
                    arguments = listOf(
                        navArgument("agentId") { type = NavType.StringType; nullable = true; defaultValue = null },
                    ),
                ) { entry ->
                    MessagesScreen(navController, entry.arguments?.getString("agentId"))
                }
                composable(
                    Routes.MEMORY,
                    arguments = listOf(
                        navArgument("agentId") { type = NavType.StringType; nullable = true; defaultValue = null },
                    ),
                ) { entry ->
                    MemoryScreen(navController, entry.arguments?.getString("agentId"))
                }
                composable(Routes.USERS) { UsersScreen(navController) }
                composable(
                    Routes.CONFIG,
                    arguments = listOf(
                        navArgument("agentId") { type = NavType.StringType; nullable = true; defaultValue = null },
                    ),
                ) { entry ->
                    ConfigScreen(navController, entry.arguments?.getString("agentId"))
                }
                composable(
                    Routes.BLOBS,
                    arguments = listOf(
                        navArgument("agentId") { type = NavType.StringType; nullable = true; defaultValue = null },
                    ),
                ) { entry ->
                    BlobsScreen(navController, entry.arguments?.getString("agentId"))
                }
                composable(
                    Routes.WORKFLOW_DETAIL,
                    arguments = listOf(navArgument("id") { type = NavType.StringType }),
                ) { entry ->
                    WorkflowDetailScreen(navController, entry.arguments?.getString("id").orEmpty())
                }
                composable(
                    Routes.TRACE,
                    arguments = listOf(navArgument("messageId") { type = NavType.LongType }),
                ) { entry ->
                    TraceScreen(navController, entry.arguments?.getLong("messageId") ?: 0L)
                }
                composable(Routes.SETTINGS) { SettingsScreen(gateVM) }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AttobotTopBar(title: String, onMenu: () -> Unit) {
    TopAppBar(
        title = {
            if (title.isNotEmpty()) {
                Text(title, color = text, fontWeight = FontWeight.Bold, fontSize = 18.sp)
            }
        },
        navigationIcon = {
            IconButton(onClick = onMenu) {
                // Text-glyph hamburger — avoids pulling in material-icons.
                Text("≡", color = text, fontSize = 22.sp)
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = panel,
            titleContentColor = text,
            navigationIconContentColor = text,
        ),
    )
}

@Composable
private fun DrawerSheetContent(
    currentRoute: String?,
    onNavigate: (String) -> Unit,
    onSettings: () -> Unit,
    onClearToken: () -> Unit,
) {
    ModalDrawerSheet(drawerContainerColor = panel) {
        // Brand header.
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            Text("attobot", color = text, fontWeight = FontWeight.Bold, fontSize = 18.sp)
            Text(" · dashboard", color = muted, fontSize = 14.sp)
        }
        HorizontalDivider(color = border)
        Column(Modifier.padding(vertical = 8.dp)) {
            DRAWER_ITEMS.forEach { item ->
                DrawerRow(
                    icon = item.icon,
                    label = item.label,
                    selected = currentRoute != null && isRoute(currentRoute, item.route),
                    onClick = { onNavigate(item.route) },
                )
            }
        }
        Spacer(Modifier.weight(1f))
        HorizontalDivider(color = border)
        Column(Modifier.padding(vertical = 8.dp)) {
            DrawerRow(icon = "🛠", label = "Settings", selected = false, onClick = onSettings)
            DrawerRow(icon = "🔒", label = "Clear token", selected = false, onClick = onClearToken)
        }
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun DrawerRow(
    icon: String,
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 1.dp)
            .clip(androidx.compose.foundation.shape.RoundedCornerShape(8.dp))
            .background(if (selected) panel2 else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(icon, fontSize = 16.sp)
        Text(
            label,
            color = if (selected) text else muted,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            fontSize = 15.sp,
            modifier = Modifier.padding(start = 14.dp),
        )
    }
}

private fun titleForRoute(route: String?): String = when {
    route == null -> ""
    route.startsWith("overview") -> "Overview"
    route.startsWith("workflows") -> "Workflows"
    route.startsWith("agents") -> "Agents"
    route.startsWith("messages") -> "Messages"
    route.startsWith("memory") -> "Memory"
    route.startsWith("users") -> "Users"
    route.startsWith("config") -> "Config"
    route.startsWith("blobs") -> "Blobs"
    route.startsWith("workflow_detail") -> "Workflow"
    route.startsWith("trace") -> "Turn trace"
    route.startsWith("settings") -> "Settings"
    else -> ""
}

/** A drawer route matches when the current route equals it or extends it with `?`. */
private fun isRoute(currentRoute: String, itemRoute: String): Boolean =
    currentRoute == itemRoute || currentRoute.startsWith("$itemRoute?")

/**
 * Top-level drawer navigation: switch tabs while preserving each screen's
 * filter/view-model state (the analogue of RN's drawer navigator behaviour).
 */
private fun NavHostController.navigateTopLevel(route: String) {
    navigate(route) {
        launchSingleTop = true
        restoreState = true
        popUpTo(graph.findStartDestination().id) { saveState = true }
    }
}
