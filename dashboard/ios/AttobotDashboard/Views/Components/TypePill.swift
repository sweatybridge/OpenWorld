import SwiftUI

/// Neutral lowercased pill (border, panel2 bg, text color). Mirrors the RN `TypePill`.
struct TypePill: View {
    let type: String
    init(_ type: String) { self.type = type }

    var body: some View {
        Text(type.lowercased())
            .font(.system(size: 12))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(Theme.panel2)
            .overlay(
                Capsule()
                    .stroke(Theme.border, lineWidth: 1)
            )
            .fixedSize()
    }
}
