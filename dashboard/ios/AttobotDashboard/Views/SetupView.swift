import SwiftUI

/// First-run / token / edit-server gate. Mirrors the RN `SetupScreen`:
/// - title/subtitle by reason
/// - Server URL field (must start with http:// or https://)
/// - optional bearer token (secure)
/// - Save persists creds and triggers reload; Cancel only when editing with an
///   existing base.
struct SetupView: View {
    let reason: GateModel.Reason
    let initialBase: String
    let initialToken: String
    let showCancel: Bool
    let onCancel: () -> Void
    let onSaved: () -> Void

    @State private var base: String
    @State private var token: String
    @State private var error: String?
    @State private var saving = false

    init(reason: Reason, initialBase: String, initialToken: String, showCancel: Bool, onCancel: @escaping () -> Void, onSaved: @escaping () -> Void) {
        self.reason = reason
        self.initialBase = initialBase
        self.initialToken = initialToken
        self.showCancel = showCancel
        self.onCancel = onCancel
        self.onSaved = onSaved
        _base = State(initialValue: initialBase)
        _token = State(initialValue: initialToken)
    }

    private var title: String {
        switch reason {
        case .firstRun: return "Connect to dashboard"
        case .token: return "Token required"
        case .edit: return "Edit server"
        }
    }

    private var subtitle: String {
        reason == .token
            ? "The server requires a bearer token (got 401)."
            : "Point the app at a reachable dashboard host."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("ATTOBOT · DASHBOARD")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.muted)
                    .padding(.bottom, 6)

                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .padding(.bottom, 4)

                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .padding(.bottom, 16)

                fieldLabel("Server URL")
                TextField("http://192.168.1.10:8088", text: $base)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .themedField()

                fieldLabel("Bearer token (optional)")
                SecureField("leave blank if the server has no token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .themedField()

                if let error {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.err)
                        .padding(.top, 10)
                }

                HStack(spacing: 10) {
                    Spacer()
                    if showCancel {
                        Button("Cancel", action: onCancel)
                            .buttonStyle(GhostButton())
                            .disabled(saving)
                    }
                    Button(action: save) {
                        Text(saving ? "Saving…" : "Save")
                    }
                    .buttonStyle(PrimaryButton())
                    .disabled(saving)
                }
                .padding(.top, 18)

                Text("The dashboard runs on the host's loopback by default (127.0.0.1:8088), so reach it via the host's LAN IP or a Tailscale address. The token is stored in the device keychain and sent as Authorization: Bearer.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)
            }
            .padding(24)
        }
        .background(Theme.bg)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    private func save() {
        let b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty {
            error = "Server URL is required."
            return
        }
        let lower = b.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            error = "Server URL must start with http:// or https://"
            return
        }
        error = nil
        saving = true
        Credentials.save(baseURL: b, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        saving = false
        onSaved()
    }
}

// MARK: - Shared button/field styles used by Setup + Settings

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .background(Theme.accent)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.vertical, 10)
            .padding(.horizontal, 20)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.6 : 1.0)
    }
}

extension View {
    /// Themed text field background/border matching the RN Setup inputs.
    func themedField() -> some View {
        self
            .font(.system(size: 14))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.bg)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
