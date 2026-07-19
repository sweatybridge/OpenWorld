import SwiftUI

/// Message stream for an agent. No poll; refreshable. Cursor paging via `before`
/// (oldest id in page) with a "Load older" button.
struct MessagesScreen: View {
    let initialAgentId: String?
    @State private var agentId: String
    @State private var before: Int64? = nil
    @State private var res = Resource<[MessageRow]>()
    private static let limit = 50

    init(initialAgentId: String?) {
        self.initialAgentId = initialAgentId
        _agentId = State(initialValue: initialAgentId ?? "")
    }

    var body: some View {
        ScreenScroll {
            Text(headerTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 12)

            AgentPills(value: agentId, onSelect: { v in agentId = v; before = nil })
                .padding(.horizontal, -16)
                .padding(.bottom, 8)

            if agentId.isEmpty {
                EmptyState("Pick an agent above.")
                    .padding(.top, 8)
            } else if let err = res.error, res.value == nil {
                ErrorState(message: err)
            } else if res.isLoading && res.value == nil {
                Spinner()
            } else {
                stream
            }
        }
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: taskKey) {
            guard !agentId.isEmpty else { return }
            res.start(load: {
                try await APIClient.getRows(APIClient.buildPath(
                    "/api/agents/\(agentId)/messages",
                    params: [("limit", String(Self.limit)), ("before", before.map { String($0) })]
                ))
            })
        }
        .onDisappear { res.cancel() }
    }

    private var taskKey: String { "\(agentId)|\(before.map(String.init) ?? "")" }

    private var headerTitle: String {
        if let a = AgentsStore.shared.agent(matching: agentId) { return "Messages · \(a.slug)" }
        if !agentId.isEmpty { return "Messages · agent \(agentId)" }
        return "Messages"
    }

    @ViewBuilder
    private var stream: some View {
        let rows = (res.value ?? []).reversed()  // oldest on top
        let oldest = rows.first?.id
        if rows.isEmpty {
            EmptyState("No messages.")
        } else {
            VStack(spacing: 10) {
                ForEach(Array(rows), id: \.id) { m in
                    MessageBubble(message: m)
                }
                if let oldest {
                    Button("Load older") { before = oldest }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct MessageBubble: View {
    let message: MessageRow
    @State private var payloadOpen = false

    private static let roleBorder: [String: Color] = [
        "tool": Theme.pend,
        "user": Theme.accent,
        "assistant": Theme.ok,
        "system": Theme.warn,
    ]

    var body: some View {
        let border = Self.roleBorder[message.role] ?? Theme.border
        let payload = message.payload ?? .null
        let toolCalls = extractToolCalls(payload)
        // Reasoning models (o-series, deepseek-r1, qwen-thinking, …) put their
        // chain-of-thought in `reasoning_content` and leave `content` empty.
        // record_assistant flattens the raw LLM message straight into the
        // payload, so reasoning_content lives at the top level — fall back to it
        // when the visible reply is blank instead of showing an empty bubble.
        let reasoning = payload["reasoning_content"]?.string ?? ""

        VStack(alignment: .leading, spacing: 4) {
            // Meta row
            HStack(spacing: 10) {
                Text(message.role.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("#\(message.id)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                if let ch = message.channel {
                    Text(ch).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                if let tc = message.toolCallId {
                    Text("tc \(tc)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                NavigationLink(value: Route.trace(messageId: Int(message.id))) {
                    Text("trace").font(.system(size: 12)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(Format.timeAgo(message.createdAt))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
            if !message.content.isEmpty {
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !reasoning.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("REASONING")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    Text(reasoning)
                        .font(.system(size: 13).italic())
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(toolCalls.enumerated()), id: \.offset) { _, tc in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tc.name ?? "")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                            JsonView(value: tc.arguments ?? tc.args ?? .null)
                        }
                        .padding(.leading, 4)
                    }
                }
                .padding(.top, 6)
            }
            if hasOtherPayload(payload) {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        payloadOpen.toggle()
                    } label: {
                        Text(payloadOpen ? "▾ payload" : "▸ payload")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                            .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    if payloadOpen {
                        JsonText(value: payload)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(
            // 3px left border colored by role
            Rectangle()
                .fill(border)
                .frame(width: 3),
            alignment: .leading
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private struct ToolCall {
        let name: String?
        let arguments: JSONValue?
        let args: JSONValue?
    }

    private func extractToolCalls(_ payload: JSONValue) -> [ToolCall] {
        guard let obj = payload.objectValue, let arr = obj["tool_calls"]?.arrayValue else { return [] }
        return arr.compactMap { item in
            guard let o = item.objectValue else { return nil }
            return ToolCall(name: o["name"]?.string, arguments: o["arguments"], args: o["args"])
        }
    }

    private func hasOtherPayload(_ payload: JSONValue) -> Bool {
        if case .object(let o) = payload { return !o.isEmpty }
        if case .null = payload { return false }
        return true
    }
}
