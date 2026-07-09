import SwiftUI

struct Spinner: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .tint(Theme.accent)
            Text("Loading…")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

struct EmptyState: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
}

struct ErrorState: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("⚠️")
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.err)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.err.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.err, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.top, 8)
    }
}
