import SwiftUI

/// Screen-level vertical scroller with content padding 16, optional
/// pull-to-refresh. Mirrors the RN `Scroll` component.
struct ScreenScroll<Content: View>: View {
    var refreshing: Bool = false
    var onRefresh: (() async -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .refreshable {
            if let onRefresh { await onRefresh() }
        }
    }
}
