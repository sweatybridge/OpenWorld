import SwiftUI

/// Full turn trace for any message id. The server resolves the turn's trigger, so
/// this works from a user, assistant, or tool message alike. Tapping a row opens
/// that instance's WorkflowDetail.
struct TraceScreen: View {
    let messageId: Int
    let navigate: (Route) -> Void
    @State private var res = Resource<[TraceRow]>()

    var body: some View {
        ScreenScroll {
            if res.isLoading && res.value == nil {
                Spinner()
            } else if let err = res.error, res.value == nil {
                ErrorState(message: err)
            } else {
                Card(title: "Correlated instances") {
                    DataTable(
                        columns: [
                            DataTableColumn<TraceRow>(id: "kind", title: "kind", width: 90) { TypePill($0.kind) },
                            DataTableColumn<TraceRow>(id: "instance", title: "instance", width: 110) { r in
                                Text(String(r.instanceId.prefix(8)))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                            },
                            DataTableColumn<TraceRow>(id: "msg", title: "message", width: 90) { r in
                                Text(r.messageId.map { "#\($0)" } ?? "—")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.text)
                            },
                            DataTableColumn<TraceRow>(id: "tc", title: "tool call", width: 150) { r in
                                if let tc = r.toolCallId {
                                    Text(tc)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                } else {
                                    Text("—").font(.system(size: 13)).foregroundStyle(Theme.text)
                                }
                            },
                            DataTableColumn<TraceRow>(id: "status", title: "status", width: 110) { StatusBadge($0.status) },
                            DataTableColumn<TraceRow>(id: "updated", title: "updated", width: 100) { r in
                                Text(Format.timeAgo(r.updatedAt))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.text)
                            },
                            DataTableColumn<TraceRow>(id: "result", title: "result", width: 160) { JsonView(value: $0.result) },
                        ],
                        rows: res.value ?? [],
                        onRow: { navigate(.workflowDetail(id: $0.instanceId)) },
                        emptyText: "No correlated instances for this turn."
                    )
                }
            }
        }
        .navigationTitle("Turn trace · msg #\(messageId)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            res.start(
                load: { try await APIClient.getRows("/api/trace/\(messageId)") },
                pollInterval: .seconds(5)
            )
        }
        .onDisappear { res.cancel() }
    }
}
