import SwiftUI

/// Users table. No poll, not refreshable.
struct UsersScreen: View {
    @State private var res = Resource<[UserRow]>()

    var body: some View {
        ScreenScroll {
            Text("Users")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 12)

            if let err = res.error, res.value == nil {
                ErrorState(message: err)
            } else if res.isLoading && res.value == nil {
                Spinner()
            } else {
                DataTable(
                    columns: [
                        DataTableColumn<UserRow>(id: "id", title: "id", width: 70) { r in
                            Text("\(r.id)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<UserRow>(id: "channel", title: "channel", width: 110) { r in
                            Text(r.channel ?? "—").font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<UserRow>(id: "ext", title: "external id", width: 150) { r in
                            Text(r.externalId ?? "—").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                        },
                        DataTableColumn<UserRow>(id: "name", title: "username") { r in
                            Text(r.username ?? r.displayName ?? "—").font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                        },
                        DataTableColumn<UserRow>(id: "tier", title: "tier", width: 90) { r in
                            Text((r.tier ?? "—").lowercased())
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.text)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 1)
                                .background(Theme.panel2)
                                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                                .clipShape(Capsule())
                                .fixedSize()
                        },
                        DataTableColumn<UserRow>(id: "updated", title: "updated", width: 90) { r in
                            Text(Format.timeAgo(r.updatedAt)).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                    ],
                    rows: res.value ?? []
                )
            }
        }
        .navigationTitle("Users")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            res.start(load: { try await APIClient.getRows("/api/users") })
        }
    }
}
