import SwiftUI

/// Collapsible pretty-printed JSON viewer. Mirrors the RN `JsonView`:
/// - A "▾ hide"/"▸ show" toggle (accent).
/// - When open, a panel2 box with horizontally-scrollable monospaced text.
/// - If the value is a JSON-encoded STRING, parse it and pretty-print the
///   parsed value (result/result fields arrive as JSON strings).
struct JsonView: View {
    let value: JSONValue?
    var defaultOpen: Bool = false

    @State private var open: Bool

    init(value: JSONValue?, defaultOpen: Bool = false) {
        self.value = value
        self.defaultOpen = defaultOpen
        _open = State(initialValue: defaultOpen)
    }

    var body: some View {
        let display = Self.rendered(value)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                open.toggle()
            } label: {
                Text(open ? "▾ hide" : "▸ show")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.accent)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            if open {
                JsonPanel(display)
            }
        }
        // Hide the toggle entirely when there is no value to show.
        .opacity(value == nil ? 0 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Pretty-prints `value`, parsing it first when it's a JSON-encoded string
    /// (result/result fields arrive that way). Shared with `JsonText`.
    static func rendered(_ value: JSONValue?) -> String {
        guard let value, !value.isNull else { return "null" }
        let toShow = value.parsedIfString()
        return toShow.pretty(indent: 2)
    }
}

/// The pretty-printed JSON panel alone, with no toggle — for places that already
/// provide their own disclosure (e.g. the ▾ result button around a node result),
/// so the value shows the moment that disclosure opens instead of behind a
/// redundant nested show button.
struct JsonText: View {
    let value: JSONValue?

    var body: some View {
        JsonPanel(JsonView.rendered(value))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Horizontally-scrollable monospaced JSON panel shared by `JsonView`/`JsonText`.
private struct JsonPanel: View {
    let display: String

    init(_ display: String) {
        self.display = display
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(display)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Theme.panel2)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, 6)
    }
}
