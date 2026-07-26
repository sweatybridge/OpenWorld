import SwiftUI

/// Horizontally-scrolling filter chips. Active = panel2 bg + accent border +
/// text color; inactive = muted text. Prepends an "all" pill (value "").
/// Mirrors the RN `FilterPills`/`Pills`.
struct FilterPills: View {
    let options: [String]
    let value: String
    let onSelect: (String) -> Void
    var allLabel: String = "all"

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill(value: "", label: allLabel)
                ForEach(options, id: \.self) { opt in
                    pill(value: opt, label: opt)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
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
