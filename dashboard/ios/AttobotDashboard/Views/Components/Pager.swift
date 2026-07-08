import SwiftUI

/// Offset pager. "‹ prev" disabled at offset 0, "next ›" disabled at the end.
/// Mirrors the RN `Pager`.
struct Pager: View {
    let offset: Int
    let limit: Int
    let total: Int
    let onPage: (Int) -> Void

    var body: some View {
        let page = (offset / limit) + 1
        let pages = max(1, Int((Double(total) / Double(limit)).rounded(.up)))
        let prevDisabled = offset == 0
        let nextDisabled = offset + limit >= total

        HStack(spacing: 14) {
            pagerButton("‹ prev", enabled: !prevDisabled) {
                onPage(max(0, offset - limit))
            }
            Text("page \(page) / \(pages) · \(total) total")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
            pagerButton("next ›", enabled: !nextDisabled) {
                onPage(offset + limit)
            }
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity)
    }

    private func pagerButton(_ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(enabled ? Theme.accent : Theme.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.4)
    }
}
