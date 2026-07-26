import SwiftUI
import UIKit

/// Loads image bytes from `path` (e.g. `/api/media/<id>/thumbnail`) via
/// `APIClient.fetchData` — the same transport and bearer auth as the JSON
/// endpoints — and decodes them into a SwiftUI `Image`. A 404 (playlist with no
/// segments) or a decode failure simply leaves the placeholder showing, so a
/// playlist without a thumbnail renders as a blank tile instead of erroring the
/// whole list. Fetches once on appear; the response is immutable so the
/// URLCache serves subsequent fetches.
struct AsyncThumb: View {
    let path: String

    @State private var uiImage: UIImage?

    var body: some View {
        Group {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Theme.panel2)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .task {
            guard uiImage == nil else { return }
            if let data = try? await APIClient.fetchData(path) {
                if !Task.isCancelled { uiImage = UIImage(data: data) }
            }
        }
    }
}
