import SwiftUI

/// Agents table (no poll; uses the shared cached AgentsStore). Row → Messages(agentId:).
struct AgentsScreen: View {
    let navigate: (Route) -> Void
    @State private var res = Resource<[AgentRow]>()

    var body: some View {
        ScreenScroll {
            Text("Agents")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 12)

            if let err = res.error, res.value == nil {
                ErrorState(message: err)
            } else if res.isLoading && res.value == nil {
                Spinner()
            } else {
                DataTable(
                    columns: [
                        DataTableColumn<AgentRow>(id: "slug", title: "slug", width: 120) { a in
                            Text(a.slug).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent).lineLimit(1)
                        },
                        DataTableColumn<AgentRow>(id: "enabled", title: "on", width: 40) { a in
                            Text(a.enabled ? "●" : "○").font(.system(size: 13)).foregroundStyle(a.enabled ? Theme.ok : Theme.err)
                        },
                        DataTableColumn<AgentRow>(id: "model", title: "model", width: 150) { a in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(a.modelName ?? "—").font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(2)
                                Text(a.apiBase ?? "").font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                        },
                        DataTableColumn<AgentRow>(id: "max_turn", title: "max turn", width: 80) { a in
                            Text("\(a.maxTurn)").font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<AgentRow>(id: "ctx", title: "ctx tokens", width: 100) { a in
                            Text(a.contextTokens.map { "\($0)" } ?? "—").font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<AgentRow>(id: "temp", title: "temp / effort", width: 120) { a in
                            Text("\(a.temperature ?? "—") / \(a.reasoningEffort ?? "—")").font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<AgentRow>(id: "msg", title: "messages", width: 90) { a in
                            Text(a.msgCount).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<AgentRow>(id: "mem", title: "memory", width: 80) { a in
                            Text(a.memCount).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<AgentRow>(id: "wf", title: "workflows", width: 90) { a in
                            Text(a.wfCount).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<AgentRow>(id: "updated", title: "updated", width: 90) { a in
                            Text(Format.timeAgo(a.updatedAt)).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                    ],
                    rows: res.value ?? [],
                    onRow: { a in navigate(.messages(agentId: String(a.id))) }
                )
            }
        }
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            res.start(load: { try await APIClient.getRows("/api/agents") })
        }
    }
}
