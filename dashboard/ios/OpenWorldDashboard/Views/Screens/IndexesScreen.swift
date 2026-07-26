import SwiftUI

/// Database indexes across all non-system schemas (OpenWorld, df, …), including
/// pgvector's hnsw/ivfflat access methods once a vector column is indexed.
/// No poll; the schema filter is derived client-side from the fetched rows
/// (mirrors the web Indexes page).
struct IndexesScreen: View {
    @State private var res = Resource<[IndexRow]>()
    @State private var schema: String = ""

    private var all: [IndexRow] { res.value ?? [] }
    private var schemas: [String] { Array(Set(all.map { $0.schemaName })).sorted() }
    private var rows: [IndexRow] {
        schema.isEmpty ? all : all.filter { $0.schemaName == schema }
    }

    var body: some View {
        ScreenScroll {
            Text("Indexes")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
                .padding(.bottom, 12)

            FilterPills(options: schemas, value: schema, onSelect: { schema = $0 }, allLabel: "all schemas")
                .padding(.horizontal, -16)
                .padding(.bottom, 8)

            Text("\(rows.count) index\(rows.count == 1 ? "" : "es")")
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
                        DataTableColumn<IndexRow>(id: "schema", title: "schema", width: 90) { r in
                            Text(r.schemaName).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                        },
                        DataTableColumn<IndexRow>(id: "table", title: "table", width: 110) { r in
                            Text(r.tableName).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                        },
                        DataTableColumn<IndexRow>(id: "index", title: "index", width: 150) { r in
                            Text(r.indexName).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.accent).lineLimit(1)
                        },
                        DataTableColumn<IndexRow>(id: "type", title: "type", width: 80) { r in
                            TypePill(r.indexType)
                        },
                        DataTableColumn<IndexRow>(id: "flags", title: "flags", width: 80) { r in
                            if r.isPrimary {
                                TypePill("PK")
                            } else if r.isUnique {
                                TypePill("UNIQUE")
                            } else {
                                Text("—").font(.system(size: 13)).foregroundStyle(Theme.muted)
                            }
                        },
                        DataTableColumn<IndexRow>(id: "size", title: "size", width: 90) { r in
                            Text(r.size).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<IndexRow>(id: "scans", title: "scans", width: 90) { r in
                            Text(r.scans).font(.system(size: 13)).foregroundStyle(Theme.text)
                        },
                        DataTableColumn<IndexRow>(id: "def", title: "definition", width: 280) { r in
                            Text(r.definition).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(2)
                        },
                    ],
                    rows: rows
                )
            }
        }
        .navigationTitle("Indexes")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            res.start(load: { try await APIClient.getRows("/api/indexes") })
        }
    }
}
