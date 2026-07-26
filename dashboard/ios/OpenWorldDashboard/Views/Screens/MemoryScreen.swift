import SwiftUI

/// Memory table. No poll; refreshable. AgentPills only.
struct MemoryScreen: View {
    let initialAgentId: String?
    @State private var agentId: String
    @State private var res = Resource<[MemoryRow]>()

    init(initialAgentId: String?) {
        self.initialAgentId = initialAgentId
        _agentId = State(initialValue: initialAgentId ?? "")
    }

    var body: some View {
        ScreenScroll {
            Text("Memory")
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
                        DataTableColumn<MemoryRow>(id: "id", title: "id", width: 80) { r in
                            Text("\(r.id)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.accent)
                        },
                        DataTableColumn<MemoryRow>(id: "agent", title: "agent", width: 70) { r in
                            Text("\(r.agentId)").font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<MemoryRow>(id: "content", title: "content") { r in
                            Text(Format.truncate(r.content ?? "", n: 160))
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.text)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        },
                        DataTableColumn<MemoryRow>(id: "enabled", title: "on", width: 40) { r in
                            Text((r.enabled ?? false) ? "●" : "○")
                                .font(.system(size: 13))
                                .foregroundStyle((r.enabled ?? false) ? Theme.ok : Theme.err)
                        },
                        DataTableColumn<MemoryRow>(id: "sources", title: "sources", width: 80) { r in
                            Text("\(r.sourceMessageIds?.count ?? 0)").font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<MemoryRow>(id: "updated", title: "updated", width: 90) { r in
                            Text(Format.timeAgo(r.updatedAt)).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                    ],
                    rows: res.value ?? []
                )
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: agentId) {
            res.start(load: {
                try await APIClient.getRows(APIClient.buildPath(
                    "/api/memory",
                    params: [("agent_id", agentId)]
                ))
            })
        }
    }
}
