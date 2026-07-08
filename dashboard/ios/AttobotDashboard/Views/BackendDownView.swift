import SwiftUI

/// Shown when the gate probe fails for a non-auth reason (host unreachable).
/// Mirrors the RN `BackendDownScreen`.
struct BackendDownView: View {
    let message: String
    let serverUrl: String
    let onRetry: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("⚠️ Cannot reach backend")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.err)
                Text(serverUrl.isEmpty ? "(no server set)" : serverUrl)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.text)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Retry", action: onRetry)
                        .buttonStyle(PrimaryButton())
                    Button("Edit server", action: onEdit)
                        .buttonStyle(GhostButton())
                    Spacer()
                }
                .padding(.top, 10)
            }
            .padding(20)
            .frame(maxWidth: 420, alignment: .leading)
            .background(Theme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
