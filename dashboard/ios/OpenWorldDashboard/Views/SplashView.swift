import SwiftUI

/// Shown while the auth gate is probing or credentials load. Mirrors RN `SplashScreen`.
struct SplashView: View {
    var body: some View {
        VStack {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}
