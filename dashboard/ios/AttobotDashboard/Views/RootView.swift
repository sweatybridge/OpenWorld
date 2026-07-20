import SwiftUI

/// Typed navigation route. Pushed onto a `NavigationStack(path:)`. Cross-links
/// (Overview -> Workflows(status:), etc.) append to the same path.
enum Route: Hashable {
    case overview
    case workflows(status: String? = nil, type: String? = nil, agent: String? = nil)
    case agents
    case messages(agentId: String? = nil)
    case memory(agentId: String? = nil)
    case users
    case config(agentId: String? = nil)
    case indexes
    case workflowDetail(id: String)
    case trace(messageId: Int)
}

struct RootView: View {
    @State private var gate = GateModel()
    @State private var path: [Route] = []
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .task {
            gate.bootstrap()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch gate.phase {
        case .loading:
            SplashView()
        case .needSetup(let reason):
            SetupView(
                reason: reason,
                initialBase: Credentials.baseURL,
                initialToken: reason == .token ? "" : Credentials.token,
                showCancel: Credentials.hasBaseURL && reason != .token,
                onCancel: { gate.reload() },
                onSaved: { gate.reload() }
            )
        case .backendDown(let message):
            BackendDownView(
                message: message,
                serverUrl: Credentials.baseURL,
                onRetry: { gate.reload() },
                onEdit: { gate.edit() }
            )
        case .ready:
            NavigationStack(path: $path) {
                MenuView(
                    gate: gate,
                    navigate: { route in path.append(route) },
                    showSettings: $showSettings
                )
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(gate: gate)
            }
        }
    }

    @ViewBuilder
    fileprivate func destination(for route: Route) -> some View {
        switch route {
        case .overview:
            OverviewScreen(navigate: { path.append($0) })
        case .workflows(let status, let type, let agent):
            WorkflowsScreen(initialStatus: status, initialType: type, initialAgent: agent, navigate: { path.append($0) })
        case .agents:
            AgentsScreen(navigate: { path.append($0) })
        case .messages(let agentId):
            MessagesScreen(initialAgentId: agentId)
        case .memory(let agentId):
            MemoryScreen(initialAgentId: agentId)
        case .users:
            UsersScreen()
        case .config(let agentId):
            ConfigScreen(initialAgentId: agentId)
        case .indexes:
            IndexesScreen()
        case .workflowDetail(let id):
            WorkflowDetailScreen(id: id)
        case .trace(let messageId):
            TraceScreen(messageId: messageId, navigate: { path.append($0) })
        }
    }
}
