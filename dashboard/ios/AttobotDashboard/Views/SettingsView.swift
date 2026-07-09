import SwiftUI

/// Settings sheet. Shows current connection info and offers Edit / Clear token.
/// Mirrors the RN `SettingsScreen`.
struct SettingsView: View {
    let gate: GateModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Settings")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .padding(.bottom, 12)

                    Card(title: "Connection") {
                        KeyValue(items: [
                            ("server", AnyView(
                                Text(Credentials.baseURL.isEmpty ? "(not set)" : Credentials.baseURL)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Theme.text)
                            )),
                            ("token", AnyView(
                                Text(Credentials.token.isEmpty ? "not set" : "set (stored in keychain)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.text)
                            )),
                        ])
                    }

                    Button("Edit server / token") { gate.edit(); dismiss() }
                        .buttonStyle(SettingsRowButton())

                    Button {
                        gate.clearToken()
                        dismiss()
                    } label: {
                        Text("Clear token")
                    }
                    .buttonStyle(SettingsRowButton(danger: true))

                    Text("attobot dashboard · read-only native iOS client. Same GET /api/* endpoints as the web console; secrets stay masked server-side.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.bg)
            .scrollContentBackground(.hidden)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct SettingsRowButton: ButtonStyle {
    var danger: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(danger ? Theme.err : Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}
