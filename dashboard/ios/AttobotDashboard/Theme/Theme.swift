import SwiftUI

/// Visual palette mirrored from the web dashboard (web/src/styles.css :root)
/// and the RN client. Status colors mirror the web `.st-*` classes.
enum Theme {
    static let bg       = Color(hex: 0x0f1115)
    static let panel    = Color(hex: 0x171a21)
    static let panel2   = Color(hex: 0x1e222b)
    static let border   = Color(hex: 0x2a2f3a)
    static let text     = Color(hex: 0xe6e8ec)
    static let muted    = Color(hex: 0x9aa3b2)
    static let accent   = Color(hex: 0x4f9cf9)
    static let ok       = Color(hex: 0x3fb950)
    static let warn     = Color(hex: 0xd29922)
    static let err      = Color(hex: 0xf85149)
    static let run      = Color(hex: 0x4f9cf9)
    static let pend     = Color(hex: 0x8b949e)
    static let cancel   = Color(hex: 0xdb6d28)

    /// status string -> foreground/border colour.
    static func statusColor(_ status: String?) -> Color {
        switch (status ?? "unknown").lowercased() {
        case "completed": return ok
        case "failed": return err
        case "running": return run
        case "pending": return pend
        case "cancelled": return cancel
        default: return pend
        }
    }
}

extension Color {
    /// Parse a 6-hex-digit #rrggbb string (with or without leading `#`).
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xff) / 255.0
        let g = Double((hex >> 8) & 0xff) / 255.0
        let b = Double(hex & 0xff) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }

    init(hex string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        let parsed = UInt32(s, radix: 16) ?? 0
        self.init(hex: parsed)
    }
}
