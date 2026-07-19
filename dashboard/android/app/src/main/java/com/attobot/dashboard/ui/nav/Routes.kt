package com.attobot.dashboard.ui.nav

import java.net.URLEncoder

/**
 * Navigation routes. Cross-links pass filters as query args (the analogue of
 * the RN `navigation.navigate('Workflows', { status })`). Path/query values are
 * URL-encoded so ids or search text with special characters round-trip safely.
 */
object Routes {
    const val OVERVIEW = "overview"
    const val WORKFLOWS = "workflows?status={status}&type={type}&agent={agent}"
    const val AGENTS = "agents"
    const val MESSAGES = "messages?agentId={agentId}"
    const val MEMORY = "memory?agentId={agentId}"
    const val USERS = "users"
    const val CONFIG = "config?agentId={agentId}"
    const val WORKFLOW_DETAIL = "workflow_detail/{id}"
    const val TRACE = "trace/{messageId}"
    const val SETTINGS = "settings"

    fun workflows(status: String? = null, type: String? = null, agent: String? = null): String {
        val params = mutableListOf<String>()
        if (status != null) params += "status=${enc(status)}"
        if (type != null) params += "type=${enc(type)}"
        if (agent != null) params += "agent=${enc(agent)}"
        return if (params.isEmpty()) "workflows" else "workflows?" + params.joinToString("&")
    }

    fun withAgent(route: String, agentId: String?): String =
        if (agentId == null) route else "$route?agentId=${enc(agentId)}"

    fun workflowDetail(id: String): String = "workflow_detail/${enc(id)}"

    fun trace(messageId: Long): String = "trace/${enc(messageId.toString())}"

    private fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")
}

/** Drawer items in display order. */
data class DrawerItem(val route: String, val icon: String, val label: String)

val DRAWER_ITEMS: List<DrawerItem> = listOf(
    DrawerItem(Routes.OVERVIEW, "🏠", "Overview"),
    DrawerItem("workflows", "🧭", "Workflows"),
    DrawerItem(Routes.AGENTS, "🤖", "Agents"),
    DrawerItem("messages", "💬", "Messages"),
    DrawerItem("memory", "🧠", "Memory"),
    DrawerItem(Routes.USERS, "👥", "Users"),
    DrawerItem("config", "⚙️", "Config"),
)
