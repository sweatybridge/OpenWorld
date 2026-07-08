import Foundation

/// Generic load/poll helper. Each screen owns a `@State Resource<T>`, calls
/// `.start(load:pollInterval:)` in `.task`, and `.refresh()` from `.refreshable`.
/// AuthError is surfaced as a message string (the gate is the primary auth
/// handler, but a token wiped mid-session shouldn't crash a screen).
@Observable
final class Resource<T> {
    var value: T?
    var error: String?
    var isLoading: Bool = false
    var isFetching: Bool = false

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var load: (() async throws -> T)?

    func start(load: @escaping () async throws -> T, pollInterval: Duration? = nil) {
        cancel()
        self.load = load
        // weak self per iteration so a leaked Resource (e.g. screen popped while
        // a poll loop is mid-sleep) can deinit and cancel its task.
        pollTask = Task { [weak self] in
            // Initial load.
            if let self {
                await self.runOnce(initial: true)
            }
            guard let interval = pollInterval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { break }
                await self.runOnce(initial: false)
            }
        }
    }

    func refresh() async {
        await runOnce(initial: false)
    }

    func cancel() {
        pollTask?.cancel()
        pollTask = nil
    }

    deinit { pollTask?.cancel() }

    private func runOnce(initial: Bool) async {
        guard let load = load else { return }
        if initial { isLoading = true }
        isFetching = true
        defer { isLoading = false; isFetching = false }
        do {
            let result = try await load()
            if !Task.isCancelled {
                value = result
                error = nil
            }
        } catch is CancellationError {
            // ignore
        } catch is AuthError {
            if !Task.isCancelled {
                error = "Unauthorized. Open Settings to set the bearer token."
            }
        } catch {
            if !Task.isCancelled {
                self.error = (error as? APIError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
