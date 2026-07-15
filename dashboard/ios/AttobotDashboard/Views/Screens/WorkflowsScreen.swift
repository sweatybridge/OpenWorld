import SwiftUI

/// Workflows list with status/type/agent filters, debounced search, paging.
/// Polls every 5s. Selecting a filter or typing resets offset to 0.
struct WorkflowsScreen: View {
    let initialStatus: String?
    let initialType: String?
    let initialAgent: String?
    let navigate: (Route) -> Void

    static let limit = 50
    static let statusOptions = ["pending", "running", "completed", "failed", "cancelled"]
    static let typeOptions = ["loop", "inbox", "cron", "send", "tool", "typing", "other"]

    @State private var status: String
    @State private var type: String
    @State private var agent: String
    @State private var q: String = ""
    @State private var debouncedQ: String = ""
    @State private var offset: Int = 0
    @State private var res = Resource<WorkflowList>()
    @State private var debounceTask: Task<Void, Never>?

    init(initialStatus: String?, initialType: String?, initialAgent: String?, navigate: @escaping (Route) -> Void) {
        self.initialStatus = initialStatus
        self.initialType = initialType
        self.initialAgent = initialAgent
        self.navigate = navigate
        _status = State(initialValue: initialStatus ?? "")
        _type = State(initialValue: initialType ?? "")
        _agent = State(initialValue: initialAgent ?? "")
    }

    private var queryKey: String { "\(status)|\(type)|\(agent)|\(debouncedQ)|\(offset)" }

    var body: some View {
        ScreenScroll {
            Text("Workflows")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                FilterPills(options: Self.statusOptions, value: status, onSelect: set(status:), allLabel: "any status")
                FilterPills(options: Self.typeOptions, value: type, onSelect: set(type:), allLabel: "any type")
                AgentPills(value: agent, onSelect: set(agent:))
            }
            .padding(.horizontal, -16)
            .padding(.bottom, 8)

            TextField("search label / id…", text: $q)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .themedField()
                .font(.system(size: 13))
                .padding(.bottom, 12)
                .onChange(of: q) { _, _ in scheduleDebounce() }

            if let err = res.error, res.value == nil {
                ErrorState(message: err)
            } else if res.isLoading && res.value == nil {
                Spinner()
            } else {
                DataTable(
                    columns: [
                        DataTableColumn<WorkflowRow>(id: "id", title: "id", width: 150) { r in
                            Text(r.id).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.accent).lineLimit(1)
                        },
                        DataTableColumn<WorkflowRow>(id: "label", title: "label") { r in
                            Text(r.label).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                        },
                        DataTableColumn<WorkflowRow>(id: "type", title: "type") { r in TypePill(r.type) },
                        DataTableColumn<WorkflowRow>(id: "agent", title: "agent") { r in
                            Text(r.agent ?? "—").font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<WorkflowRow>(id: "status", title: "status") { r in StatusBadge(r.status) },
                        DataTableColumn<WorkflowRow>(id: "updated", title: "updated") { r in
                            Text(Format.timeAgo(r.updatedAt)).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                    ],
                    rows: res.value?.rows ?? [],
                    onRow: { r in navigate(.workflowDetail(id: r.id)) }
                )
            }

            Pager(
                offset: offset,
                limit: Self.limit,
                total: res.value?.total ?? 0,
                onPage: { offset = $0 }
            )
        }
        .navigationTitle("Workflows")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: queryKey) {
            res.start(
                load: {
                    try await APIClient.get(APIClient.buildPath(
                        "/api/workflows",
                        params: [
                            ("limit", String(Self.limit)),
                            ("offset", String(offset)),
                            ("status", status),
                            ("type", type),
                            ("agent", agent),
                            ("q", debouncedQ),
                        ]
                    ))
                },
                pollInterval: .seconds(5)
            )
        }
        .onDisappear { res.cancel() }
    }

    private func set(status v: String) { status = v; offset = 0 }
    private func set(type v: String) { type = v; offset = 0 }
    private func set(agent v: String) { agent = v; offset = 0 }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            debouncedQ = q
            offset = 0
        }
    }
}
