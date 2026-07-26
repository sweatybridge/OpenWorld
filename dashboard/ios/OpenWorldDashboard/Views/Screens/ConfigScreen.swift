import SwiftUI

/// Config table. No poll; refreshable. AgentPills + secret-redaction hint.
struct ConfigScreen: View {
    let initialAgentId: String?
    @State private var agentId: String
    @State private var res = Resource<[ConfigRow]>()

    init(initialAgentId: String?) {
        self.initialAgentId = initialAgentId
        _agentId = State(initialValue: initialAgentId ?? "")
    }

    var body: some View {
        ScreenScroll {
            Text("Config")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 12)

            AgentPills(value: agentId, onSelect: { agentId = $0 })
                .padding(.horizontal, -16)
                .padding(.bottom, 8)

            Text("secrets are redacted server-side — use psql to read values")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .padding(.bottom, 12)

            if let err = res.error, res.value == nil {
                ErrorState(message: err)
            } else if res.isLoading && res.value == nil {
                Spinner()
            } else {
                DataTable(
                    columns: [
                        DataTableColumn<ConfigRow>(id: "agent", title: "agent", width: 70) { r in
                            Text("\(r.agentId)").font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<ConfigRow>(id: "key", title: "key", width: 160) { r in
                            Text(r.key).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.accent).lineLimit(1)
                        },
                        DataTableColumn<ConfigRow>(id: "value", title: "value") { r in
                            if r.secret {
                                Text("•••••• (secret)")
                                    .font(.system(size: 13, design: .default).italic())
                                    .foregroundStyle(Theme.muted)
                            } else {
                                JsonView(value: r.value)
                            }
                        },
                        DataTableColumn<ConfigRow>(id: "secret", title: "secret", width: 70) { r in
                            Text(r.secret ? "yes" : "no").font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<ConfigRow>(id: "updated", title: "updated", width: 90) { r in
                            Text(Format.timeAgo(r.updatedAt)).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                    ],
                    rows: res.value ?? []
                )
            }
        }
        .navigationTitle("Config")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: agentId) {
            res.start(load: {
                try await APIClient.getRows(APIClient.buildPath(
                    "/api/config",
                    params: [("agent_id", agentId)]
                ))
            })
        }
    }
}
