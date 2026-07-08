import SwiftUI

/// Lowercased pill tinted by the status color. Mirrors the web `.badge.st-*`.
struct StatusBadge: View {
    let status: String?
    init(_ status: String?) { self.status = status }

    var body: some View {
        let v = (status ?? "unknown")
        let c = Theme.statusColor(v)
        Text(v.lowercased())
            .font(.system(size: 12))
            .foregroundStyle(c)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .overlay(
                Capsule()
                    .stroke(c, lineWidth: 1)
            )
            // Capsule geometry needs an intrinsic size to draw the border tight.
            .fixedSize()
    }
}
