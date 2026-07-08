import SwiftUI

/// Workflow detail. Polls /api/workflows/{id}. Header + Instance info + Final
/// result + Node graph (filtered to current execution) + Executions + df.explain.
struct WorkflowDetailScreen: View {
    let id: String
    @State private var res = Resource<WorkflowDetail>()

    var body: some View {
        ScreenScroll {
            if res.isLoading && res.value == nil {
                Spinner()
            } else if let err = res.error, res.value == nil {
                ErrorState(message: err)
            } else if let d = res.value {
                detailBody(d: d)
            } else {
                EmptyState("Not found.")
            }
        }
        .navigationTitle("Workflow")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            res.start(
                load: { try await APIClient.get("/api/workflows/\(id)") },
                pollInterval: .seconds(5)
            )
        }
        .onDisappear { res.cancel() }
    }

    @ViewBuilder
    private func detailBody(d: WorkflowDetail) -> some View {
        let info = d.info ?? [:]
        let label = info["label"]?.string ?? id
        let nodes = d.nodes ?? []
        let currentNodes = nodes.filter { $0.executionId == d.currentExecutionId }
        let filtered = !currentNodes.isEmpty && currentNodes.count != nodes.count && d.currentExecutionId != nil

        VStack(alignment: .leading, spacing: 4) {
            Text(id)
                .font(.system(size: 15, design: .monospaced, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                StatusBadge(info["status"]?.string)
            }
        }
        .padding(.bottom, 16)

        Card(title: "Instance info") {
            KeyValue(items: [
                ("status", AnyView(StatusBadge(info["status"]?.string))),
                ("label", AnyView(Text(str(info["label"])).font(.system(size: 13)).foregroundStyle(Theme.text))),
                ("function", AnyView(Text(str(info["function_name"])).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text))),
                ("version", AnyView(Text(str(info["function_version"])).font(.system(size: 13)).foregroundStyle(Theme.text))),
                ("current execution", AnyView(Text(d.currentExecutionId ?? "—").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text))),
                ("output", AnyView(JsonView(value: info["output"]))),
            ])
        }

        Card(title: "Final result") {
            JsonView(value: d.result, defaultOpen: true)
        }

        Card(title: filtered ? "Node graph · execution \(d.currentExecutionId ?? "")" : "Node graph") {
            NodeTree(nodes: currentNodes)
        }

        Card(title: "Executions") {
            DataTable(
                columns: [
                    DataTableColumn<[String: JSONValue]>(id: "execution_id", title: "execution", width: 150) { r in
                        Text(str(r["execution_id"]))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    },
                    DataTableColumn<[String: JSONValue]>(id: "status", title: "status") { r in
                        StatusBadge(r["status"]?.string)
                    },
                    DataTableColumn<[String: JSONValue]>(id: "events", title: "events") { r in
                        Text(str(r["event_count"])).font(.system(size: 13)).foregroundStyle(Theme.text)
                    },
                    DataTableColumn<[String: JSONValue]>(id: "duration", title: "duration") { r in
                        Text(Format.formatMs(r["duration_ms"]?.numericValue)).font(.system(size: 13)).foregroundStyle(Theme.text)
                    },
                    DataTableColumn<[String: JSONValue]>(id: "output", title: "output") { r in
                        JsonView(value: r["output"])
                    },
                ],
                rows: d.executions ?? []
            )
        }

        if let explain = d.explain, !explain.isEmpty {
            Card(title: "df.explain") {
                Text(explain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func str(_ v: JSONValue?) -> String {
        guard let v, !v.isNull else { return "—" }
        if let s = v.string { return s }
        if let n = v.numberValue {
            if n == n.rounded() && abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        }
        if let b = v.boolValue { return String(b) }
        return "—"
    }
}
