import SwiftUI

/// The drawer-as-List: brand header, 9 navigation items, footer with Settings
/// (sheet) + Clear token (wipe + reload). This is the NavigationStack root.
struct MenuView: View {
    let gate: GateModel
    let navigate: (Route) -> Void
    @Binding var showSettings: Bool

    private struct Item {
        let route: Route
        let icon: String
        let label: String
    }

    private let items: [Item] = [
        Item(route: .overview, icon: "🏠", label: "Overview"),
        Item(route: .workflows(), icon: "🧭", label: "Workflows"),
        Item(route: .agents, icon: "🤖", label: "Agents"),
        Item(route: .messages(), icon: "💬", label: "Messages"),
        Item(route: .memory(), icon: "🧠", label: "Memory"),
        Item(route: .users, icon: "👥", label: "Users"),
        Item(route: .config(), icon: "⚙️", label: "Config"),
    ]

    var body: some View {
        List {
            // Brand header
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("attobot")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(" · dashboard")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            .listRowSeparator(.hidden)

            // Navigation items
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button {
                    navigate(item.route)
                } label: {
                    HStack(spacing: 14) {
                        Text(item.icon).font(.system(size: 16))
                            .frame(width: 22, alignment: .center)
                        Text(item.label)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                            .opacity(0.6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8))
                .listRowSeparator(.visible, edges: .bottom)
            }

            // Footer actions
            Section {
                Button {
                    showSettings = true
                } label: {
                    HStack(spacing: 14) {
                        Text("🛠").font(.system(size: 16)).frame(width: 22, alignment: .center)
                        Text("Settings").font(.system(size: 15)).foregroundStyle(Theme.text)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    gate.clearToken()
                } label: {
                    HStack(spacing: 14) {
                        Text("🔒").font(.system(size: 16)).frame(width: 22, alignment: .center)
                        Text("Clear token").font(.system(size: 15)).foregroundStyle(Theme.text)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8))
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 10)
        .scrollContentBackground(.hidden)
        .background(Theme.panel)
        .navigationTitle("Menu")
        .navigationBarTitleDisplayMode(.inline)
    }
}
