import SwiftUI

/// Lifecycle table. Polls (5s); refreshable. AgentPills + fixed limit 200.
struct LifecycleScreen: View {
    let initialAgentId: String?
    @State private var agentId: String
    @State private var res = Resource<[LifecycleRow]>()

    init(initialAgentId: String?) {
        self.initialAgentId = initialAgentId
        _agentId = State(initialValue: initialAgentId ?? "")
    }

    var body: some View {
        ScreenScroll {
            Text("Lifecycle")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 12)

            AgentPills(value: agentId, onSelect: { agentId = $0 })
                .padding(.horizontal, -16)
                .padding(.bottom, 8)

            if let err = res.error, res.value == nil {
                ErrorState(message: err)
            } else if res.isLoading && res.value == nil {
                Spinner()
            } else {
                DataTable(
                    columns: [
                        DataTableColumn<LifecycleRow>(id: "id", title: "id", width: 70) { r in
                            Text("\(r.id)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<LifecycleRow>(id: "agent", title: "agent", width: 70) { r in
                            Text(r.agentId.map { "\($0)" } ?? "—").font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<LifecycleRow>(id: "event", title: "event", width: 130) { r in
                            Text(r.event ?? "—").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<LifecycleRow>(id: "detail", title: "detail") { r in
                            JsonView(value: r.detail)
                        },
                        DataTableColumn<LifecycleRow>(id: "time", title: "time", width: 90) { r in
                            Text(Format.timeAgo(r.createdAt)).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                    ],
                    rows: res.value ?? []
                )
            }
        }
        .navigationTitle("Lifecycle")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: agentId) {
            res.start(
                load: {
                    try await APIClient.getRows(APIClient.buildPath(
                        "/api/lifecycle",
                        params: [("limit", "200"), ("agent_id", agentId)]
                    ))
                },
                pollInterval: .seconds(5)
            )
        }
        .onDisappear { res.cancel() }
    }
}
