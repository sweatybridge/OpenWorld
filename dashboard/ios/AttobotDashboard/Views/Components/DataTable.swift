import SwiftUI

/// Wide, horizontally-scrolling table. Rows are flat (admin views are small).
/// Mirrors the RN `DataTable`.
struct DataTableColumn<Row> {
    let id: String
    let title: String
    let width: CGFloat?
    let cell: (Row) -> AnyView

    init<C: View>(
        id: String,
        title: String,
        width: CGFloat? = nil,
        @ViewBuilder cell: @escaping (Row) -> C
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.cell = { row in AnyView(cell(row)) }
    }
}

struct DataTable<Row: Hashable>: View {
    let columns: [DataTableColumn<Row>]
    let rows: [Row]
    var onRow: ((Row) -> Void)? = nil
    var emptyText: String = "No rows."

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 0) {
                    ForEach(columns, id: \.id) { col in
                        Text(col.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .frame(width: col.width, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                .background(Theme.panel2)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.border).frame(height: 1)
                }
                if rows.isEmpty {
                    Text(emptyText)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        rowView(row)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        Group {
            if onRow != nil {
                Button {
                    onRow?(row)
                } label: {
                    rowContent(row)
                }
                .buttonStyle(RowHighlightStyle())
            } else {
                rowContent(row)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private func rowContent(_ row: Row) -> some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.id) { col in
                col.cell(row)
                    .frame(width: col.width, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Press-state highlight (panel2 on press) matching the RN `pressed` style.
struct RowHighlightStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.panel2 : Color.clear)
    }
}
