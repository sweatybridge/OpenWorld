import SwiftUI

/// Overview dashboard. Polls /api/overview + /api/workflows?status=failed&limit=8.
struct OverviewScreen: View {
    let navigate: (Route) -> Void

    @State private var overviewRes = Resource<Overview>()
    @State private var failedRes = Resource<WorkflowList>()

    var body: some View {
        ScreenScroll {
            if overviewRes.isLoading && overviewRes.value == nil {
                Spinner()
            } else if let err = overviewRes.error, overviewRes.value == nil {
                ErrorState(message: err)
            } else if let o = overviewRes.value {
                content(o: o)
            } else {
                Spinner()
            }
        }
        .navigationTitle("Overview")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            overviewRes.start(
                load: { try await APIClient.get("/api/overview") },
                pollInterval: .seconds(5)
            )
            failedRes.start(
                load: {
                    try await APIClient.get(APIClient.buildPath(
                        "/api/workflows",
                        params: [("status", "failed"), ("limit", "8")]
                    ))
                },
                pollInterval: .seconds(5)
            )
        }
        .onDisappear {
            overviewRes.cancel()
            failedRes.cancel()
        }
    }

    @ViewBuilder
    private func content(o: Overview) -> some View {
        let m = o.metrics ?? [:]
        Text("Overview")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(Theme.text)
            .padding(.bottom, 12)

        let metrics: [(String, String)] = [
            ("total instances", metricText(m["total_instances"])),
            ("running", metricText(m["running_instances"])),
            ("completed", metricText(m["completed_instances"])),
            ("failed", metricText(m["failed_instances"])),
            ("total executions", metricText(m["total_executions"])),
            ("total events", metricText(m["total_events"])),
        ]

        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(metrics, id: \.0) { label, val in
                MetricTile(value: val, label: label)
            }
        }
        .padding(.bottom, 8)

        Card(title: "pg_durable worker") {
            if let w = o.worker {
                workerBody(w: w)
            } else {
                EmptyState("Worker liveness unavailable.")
            }
        }

        Card(title: "By status") {
            if let bs = o.byStatus, !bs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(bs.enumerated()), id: \.offset) { _, r in
                        Button {
                            navigate(.workflows(status: r.status))
                        } label: {
                            HStack(spacing: 10) {
                                StatusBadge(r.status)
                                Spacer()
                                Text(r.count)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.muted)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                EmptyState("No instances.")
            }
        }

        Card(title: "By type") {
            if let bt = o.byType, !bt.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(bt.enumerated()), id: \.offset) { _, r in
                        Button {
                            navigate(.workflows(type: r.type))
                        } label: {
                            HStack(spacing: 10) {
                                TypePill(r.type ?? "")
                                Spacer()
                                Text(r.count)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.muted)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                EmptyState("No instances.")
            }
        }

        Card(title: "Agents") {
            if let agents = o.agents, !agents.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(agents.enumerated()), id: \.offset) { _, a in
                        Button {
                            navigate(.messages(agentId: String(a.id)))
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(a.enabled ? Theme.ok : Theme.err)
                                    .frame(width: 9, height: 9)
                                Text(a.slug)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.text)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                EmptyState("No agents.")
            }
        }

        Card(title: "Recent failed workflows") {
            if failedRes.isLoading && failedRes.value == nil {
                Spinner()
            } else {
                DataTable(
                    columns: [
                        DataTableColumn<WorkflowRow>(id: "id", title: "id", width: 140) { r in
                            Text(r.id)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                                .lineLimit(1)
                        },
                        DataTableColumn<WorkflowRow>(id: "label", title: "label") { r in
                            Text(r.label).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                        },
                        DataTableColumn<WorkflowRow>(id: "type", title: "type") { r in
                            TypePill(r.type)
                        },
                        DataTableColumn<WorkflowRow>(id: "status", title: "status") { r in
                            StatusBadge(r.status)
                        },
                        DataTableColumn<WorkflowRow>(id: "updated", title: "updated") { r in
                            Text(Format.timeAgo(r.updatedAt)).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                    ],
                    rows: failedRes.value?.rows ?? [],
                    onRow: { r in navigate(.workflowDetail(id: r.id)) }
                )
            }
        }
    }

    @ViewBuilder
    private func workerBody(w: Overview.Worker) -> some View {
        let alive = (w.ageSeconds ?? 999) < 15
        KeyValue(items: [
            ("status", AnyView(
                HStack(spacing: 8) {
                    Circle()
                        .fill(alive ? Theme.ok : Theme.err)
                        .frame(width: 9, height: 9)
                    Text(alive ? "alive" : "stale / down")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                }
            )),
            ("last heartbeat", AnyView(
                Text(w.ageSeconds != nil ? String(format: "%.1fs ago", w.ageSeconds!) : "—")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
            )),
            ("started", AnyView(
                Text(Format.formatDateTime(w.startedAt))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
            )),
        ])
    }

    private func metricText(_ v: JSONValue?) -> String {
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

private struct MetricTile: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
