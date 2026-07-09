import SwiftUI

/// Blobs table. No poll; refreshable. AgentPills only.
struct BlobsScreen: View {
    let initialAgentId: String?
    @State private var agentId: String
    @State private var res = Resource<[BlobRow]>()

    init(initialAgentId: String?) {
        self.initialAgentId = initialAgentId
        _agentId = State(initialValue: initialAgentId ?? "")
    }

    var body: some View {
        ScreenScroll {
            Text("Blobs")
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
                        DataTableColumn<BlobRow>(id: "agent", title: "agent", width: 70) { r in
                            Text(r.agentId.map { "\($0)" } ?? "—").font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<BlobRow>(id: "hash", title: "hash", width: 200) { r in
                            Text(Format.truncate(r.hash ?? "", n: 24))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                        },
                        DataTableColumn<BlobRow>(id: "size", title: "size", width: 90) { r in
                            Text(Format.formatBytes(r.size)).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<BlobRow>(id: "created", title: "created", width: 90) { r in
                            Text(Format.timeAgo(r.createdAt)).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                    ],
                    rows: res.value ?? []
                )
            }
        }
        .navigationTitle("Blobs")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: agentId) {
            res.start(load: {
                try await APIClient.getRows(APIClient.buildPath(
                    "/api/blobs",
                    params: [("agent_id", agentId)]
                ))
            })
        }
    }
}
