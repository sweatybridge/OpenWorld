import SwiftUI

/// Panel-backed card with optional uppercase header (title left, right flush),
/// divider, and padded body. Mirrors the RN `Card` component.
struct Card<HeaderRight: View, Body: View>: View {
    var title: String? = nil
    var right: () -> HeaderRight
    var content: () -> Body

    init(
        title: String? = nil,
        @ViewBuilder right: @escaping () -> HeaderRight,
        @ViewBuilder content: @escaping () -> Body
    ) {
        self.title = title
        self.right = right
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil {
                HStack {
                    if let title {
                        Text(title.uppercased())
                            .font(.system(size: 14, weight: .medium))
                            .tracking(0.4)
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer().frame(maxWidth: .infinity)
                    }
                    right()
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(Theme.panel2)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Theme.border)
                        .frame(height: 1)
                }
            }
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.panel)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 16)
    }
}

extension Card where HeaderRight == EmptyView {
    init(@ViewBuilder content: @escaping () -> Body) {
        self.init(title: nil, right: { EmptyView() }, content: content)
    }
    init(title: String?, @ViewBuilder content: @escaping () -> Body) {
        self.init(title: title, right: { EmptyView() }, content: content)
    }
}
