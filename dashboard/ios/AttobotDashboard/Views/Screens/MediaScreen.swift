import SwiftUI

/// ffmpeg.hls_playlists: media the agent ingested via `ffmpeg.hls` (in the SQL
/// tool) and may have sent with send_photo/send_video/send_audio. Each row's
/// thumbnail is computed on demand (server-side, from the first segment) and
/// fetched via AsyncThumb. No poll; mirrors the web Media page.
struct MediaScreen: View {
    @State private var res = Resource<[MediaRow]>()

    private var rows: [MediaRow] { res.value ?? [] }

    var body: some View {
        ScreenScroll {
            Text("Media")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 12)

            Text("\(rows.count) playlist\(rows.count == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .padding(.bottom, 12)

            if let err = res.error, res.value == nil {
                ErrorState(message: err)
            } else if res.isLoading && res.value == nil {
                Spinner()
            } else {
                DataTable(
                    columns: [
                        DataTableColumn<MediaRow>(id: "thumb", title: "", width: 110) { r in
                            AsyncThumb(path: "/api/media/\(r.id)/thumbnail")
                        },
                        DataTableColumn<MediaRow>(id: "id", title: "id", width: 70) { r in
                            Text(r.id).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                        },
                        DataTableColumn<MediaRow>(id: "segs", title: "segments", width: 90) { r in
                            Text(r.segmentCount).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<MediaRow>(id: "dur", title: "duration", width: 90) { r in
                            Text(Format.formatDuration(r.totalDuration)).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<MediaRow>(id: "size", title: "size", width: 90) { r in
                            Text(Format.formatBytes(Int64(r.totalSize))).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<MediaRow>(id: "target", title: "target", width: 70) { r in
                            Text("\(r.targetDuration)s").font(.system(size: 13)).foregroundStyle(Theme.muted)
                        },
                    ],
                    rows: rows
                )
            }
        }
        .navigationTitle("Media")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            res.start(load: { try await APIClient.getRows("/api/media") })
        }
    }
}
