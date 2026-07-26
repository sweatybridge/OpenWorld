import Foundation

/// Auth gate state machine. Mirrors the RN `RootNav`/`gate.ts`:
/// `.loading` -> `.needSetup(reason)` / `.backendDown(message)` / `.ready`.
/// On init it loads credentials then probes `GET /api/overview`. `reload()`
/// re-probes; `edit()` opens the Setup screen; `save()`/`clearToken()` mutate
/// creds and re-probe.
@Observable
final class GateModel {
    enum Reason: Equatable { case firstRun, token, edit }
    enum Phase: Equatable {
        case loading
        case needSetup(Reason)
        case backendDown(String)
        case ready
    }

    var phase: Phase = .loading

    /// Bumped on reload() so the probe re-runs even when nothing else changed.
    private(set) var version: Int = 0
    private var probeTask: Task<Void, Never>?

    init() {
        Credentials.load()
    }

    func reload() {
        version &+= 1
        probe()
    }

    /// Begin the initial probe (called from RootView .task).
    func bootstrap() {
        guard phase == .loading else { return }
        probe()
    }

    func edit() {
        phase = .needSetup(.edit)
    }

    func save(base: String, token tok: String) {
        Credentials.save(baseURL: base, token: tok)
        reload()
    }

    func clearToken() {
        Credentials.clearToken()
        reload()
    }

    // MARK: - Probe

    private func probe() {
        probeTask?.cancel()
        guard Credentials.hasBaseURL else {
            phase = .needSetup(.firstRun)
            return
        }
        // Keep the current phase visible while probing (avoids a splash flash
        // on reload when already ready). The initial probe runs while phase is
        // still .loading (set in the declaration), so the splash shows then.
        probeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let _: Overview = try await APIClient.get("/api/overview")
                if !Task.isCancelled { self.phase = .ready }
            } catch is AuthError {
                if !Task.isCancelled { self.phase = .needSetup(.token) }
            } catch is CancellationError {
                // ignore
            } catch {
                if !Task.isCancelled { self.phase = .backendDown(message(for: error)) }
            }
        }
    }

    private func message(for error: Error) -> String {
        if let api = error as? APIError { return api.errorDescription ?? "Unknown error" }
        return error.localizedDescription
    }
}
