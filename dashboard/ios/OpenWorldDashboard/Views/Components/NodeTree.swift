import SwiftUI

/// Recursive renderer of a pg_durable node graph. Roots are nodes no other node
/// points at via left_node/right_node; children follow those pointers.
/// In plan order (default) the sink renders on top and data flows up; flip to
/// execution order to put SQL sources on top with data flowing down. Mirrors
/// the web `NodeTree`.
struct NodeTree: View {
    let nodes: [InstanceNode]
    var flipped: Bool = false

    var body: some View {
        if nodes.isEmpty {
            EmptyState("No nodes recorded for this instance.")
        } else {
            let byId = Dictionary(uniqueKeysWithValues: nodes.map { ($0.nodeId, $0) })
            let childIds = Set(nodes.flatMap { n in
                [n.leftNode, n.rightNode].compactMap { $0 }
            })
            let roots = nodes.filter { !childIds.contains($0.nodeId) }
            if flipped {
                let layout = Self.flippedLayout(byId: byId, roots: roots)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(layout.order.enumerated()), id: \.element.nodeId) { _, n in
                        NodeLine(node: n, depth: layout.leafDepth[n.nodeId] ?? 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(roots.enumerated()), id: \.element.nodeId) { _, root in
                        NodeRow(node: root, byId: byId, depth: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Post-order flattening for execution order: leaves (sources) first, sink
    /// last, with each node's indent = its distance from the farthest leaf below.
    /// Cycles (which a well-formed plan never has) are treated as leaves.
    private static func flippedLayout(
        byId: [String: InstanceNode],
        roots: [InstanceNode]
    ) -> (order: [InstanceNode], leafDepth: [String: Int]) {
        var leafDepth: [String: Int] = [:]
        func depthOf(_ id: String, _ stack: Set<String>) -> Int {
            if let cached = leafDepth[id] { return cached }
            guard let n = byId[id], !stack.contains(id) else { return 0 }
            var next = stack
            next.insert(id)
            var d = 0
            if n.leftNode != nil || n.rightNode != nil {
                let l = n.leftNode.map { depthOf($0, next) } ?? 0
                let r = n.rightNode.map { depthOf($0, next) } ?? 0
                d = 1 + max(l, r)
            }
            leafDepth[id] = d
            return d
        }
        var order: [InstanceNode] = []
        func emit(_ n: InstanceNode, _ stack: Set<String>) {
            if stack.contains(n.nodeId) { return }
            var next = stack
            next.insert(n.nodeId)
            if let l = n.leftNode.flatMap({ byId[$0] }) { emit(l, next) }
            if let r = n.rightNode.flatMap({ byId[$0] }) { emit(r, next) }
            order.append(n)
        }
        for r in roots { _ = depthOf(r.nodeId, []) }
        for r in roots { emit(r, []) }
        return (order, leafDepth)
    }
}

/// One node's line (marker, type, named result, query) plus its collapsible
/// result, indented by `depth * 18`. `depth` is depth-from-sink in plan order
/// and depth-from-leaf in execution order.
private struct NodeLine: View {
    let node: InstanceNode
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
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
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
                        JsonText(value: result)
                    }
                }
                .padding(.leading, CGFloat(depth) * 18 + 14)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Plan order: sink-rooted, pre-order DFS, indent grows with depth so a
/// consumer renders above the inputs feeding it.
private struct NodeRow: View {
    let node: InstanceNode
    let byId: [String: InstanceNode]
    let depth: Int

    var body: some View {
        let left = node.leftNode.flatMap { byId[$0] }
        let right = node.rightNode.flatMap { byId[$0] }

        VStack(alignment: .leading, spacing: 2) {
            NodeLine(node: node, depth: depth)
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
