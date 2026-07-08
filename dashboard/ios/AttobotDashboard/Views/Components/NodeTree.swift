import SwiftUI

/// Recursive renderer of a pg_durable node graph. Roots are nodes no other node
/// points at via left_node/right_node; children follow those pointers.
/// Mirrors the RN `NodeTree`.
struct NodeTree: View {
    let nodes: [InstanceNode]

    var body: some View {
        if nodes.isEmpty {
            EmptyState("No nodes recorded for this instance.")
        } else {
            let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.nodeId, $0) })
            let childIds = Set(nodes.flatMap { n in
                [n.leftNode, n.rightNode].compactMap { $0 }
            })
            let roots = nodes.filter { !childIds.contains($0.nodeId) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(roots.enumerated()), id: \.element.nodeId) { _, root in
                    NodeRow(node: root, byId: byId, depth: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct NodeRow: View {
    let node: InstanceNode
    let byId: [String: InstanceNode]
    let depth: Int

    @State private var openResult = false

    private static let markers: [String: String] = [
        "completed": "✓",
        "failed": "✗",
        "running": "⏳",
        "pending": "○",
        "cancelled": "✗",
    ]

    var body: some View {
        let left = node.leftNode.flatMap { byId[$0] }
        let right = node.rightNode.flatMap { byId[$0] }
        let marker = Self.markers[node.status ?? ""] ?? "•"
        let markerColor = Theme.statusColor(node.status)
        let queryOne = node.query.map { Format.truncate($0, n: 90) } ?? ""

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(markerColor)
                    .frame(width: 14, alignment: .leading)
                Text(node.nodeType)
                    .font(.system(size: 13, design: .monospaced, weight: .bold))
                    .foregroundStyle(Theme.accent)
                if let rn = node.resultName {
                    Text("|=> \(rn)")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.warn)
                }
                if !queryOne.isEmpty {
                    Text(queryOne)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            .padding(.leading, CGFloat(depth) * 18)
            .padding(.vertical, 2)

            if let result = node.result, !result.isNull {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        openResult.toggle()
                    } label: {
                        Text(openResult ? "▾ result" : "▸ result")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    if openResult {
                        JsonView(value: result, defaultOpen: false)
                    }
                }
                .padding(.leading, CGFloat(depth) * 18 + 14)
                .padding(.top, 2)
            }
            if let left {
                NodeRow(node: left, byId: byId, depth: depth + 1)
            }
            if let right {
                NodeRow(node: right, byId: byId, depth: depth + 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
