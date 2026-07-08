import SwiftUI

/// Agent picker chips backed by the shared `AgentsStore` (cached ~60s).
/// "all agents" (value "") + one pill per agent (value = String(id), label = slug).
struct AgentPills: View {
    let value: String
    let onSelect: (String) -> Void

    var body: some View {
        let agents = AgentsStore.shared.agents
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill(value: "", label: "all agents")
                ForEach(agents, id: \.id) { a in
                    pill(value: String(a.id), label: a.slug)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .task {
            AgentsStore.shared.ensureLoaded()
        }
    }

    private func pill(value: String, label: String) -> some View {
        let active = value == self.value
        return Button {
            onSelect(value)
        } label: {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(active ? Theme.text : Theme.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(active ? Theme.panel2 : Theme.panel)
                .overlay(
                    Capsule()
                        .stroke(active ? Theme.accent : Theme.border, lineWidth: 1)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
