import Foundation

/// Shared, cached agent list used by AgentPills + Messages. Mirrors the RN
/// `useAgents()` hook (TanStack Query with `staleTime: 60s`). Single shared
/// instance so every AgentPills on screen reuses the same fetch.
@Observable
final class AgentsStore {
    static let shared = AgentsStore()

    var agents: [AgentRow] = []
    var error: String?
    var isLoading: Bool = false

    private var loadedAt: Date = .distantPast
    private let staleAfter: TimeInterval = 60
    private var fetchTask: Task<Void, Never>?

    /// Returns the currently cached agents, fetching if stale. Safe to call
    /// repeatedly.
    func ensureLoaded() {
        if Date().timeIntervalSince(loadedAt) < staleAfter && !agents.isEmpty { return }
        if isLoading { return }
        fetchTask?.cancel()
        isLoading = true
        fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rows: [AgentRow] = try await APIClient.getRows("/api/agents")
                if !Task.isCancelled {
                    self.agents = rows
                    self.error = nil
                    self.loadedAt = Date()
                }
            } catch is CancellationError {
                // ignore
            } catch is AuthError {
                if !Task.isCancelled { self.error = "Unauthorized." }
            } catch {
                if !Task.isCancelled { self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription }
            }
            if !Task.isCancelled { self.isLoading = false }
        }
    }

    func agent(matching id: String) -> AgentRow? {
        agents.first(where: { String($0.id) == id })
    }

    /// Force a refresh on the next ensureLoaded (e.g. after pull-to-refresh).
    func invalidate() {
        loadedAt = .distantPast
    }
}
