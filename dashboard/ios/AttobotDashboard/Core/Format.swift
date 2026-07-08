import Foundation

/// Verbatim port of dashboard/web/src/format.ts / dashboard/mobile/src/lib/format.ts.
/// Pure helpers shared across screens; `Date()` and `DateFormatter` replace the
/// JS `Date`/`toLocaleString` used in the RN client.

enum Format {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parse an ISO8601 string (with or without fractional seconds / timezone).
    static func parseISO(_ iso: String) -> Date? {
        if let d = isoFormatter.date(from: iso) { return d }
        let fallback = ISO8601DateFormatter()
        if let d = fallback.date(from: iso) { return d }
        // Fallback for "Z-less" RFC3339 with offset, e.g. 2024-01-01T00:00:00+02:00
        let alt = ISO8601DateFormatter()
        alt.formatOptions = [.withInternetDateTime]
        return alt.date(from: iso)
    }

    static func timeAgo(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        guard let t = parseISO(iso) else { return iso }
        let s = max(0, floor(Date().timeIntervalSince(t)))
        if s < 5 { return "just now" }
        if s < 60 { return "\(Int(s))s ago" }
        let m = Int(s) / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        if h < 24 { return "\(h)h ago" }
        let d = h / 24
        return "\(d)d ago"
    }

    static func formatDateTime(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        guard let t = parseISO(iso) else { return iso }
        return Self.dateTimeFormatter.string(from: t)
    }

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    /// Format a byte count. nil → "—"; <1024 "N B"; then KB/MB/GB/TB, 1 decimal
    /// unless the value is >=100 (then 0 decimals). Mirrors RN `formatBytes`.
    static func formatBytes(_ n: Int64?) -> String {
        guard let n else { return "—" }
        return formatBytesNum(Double(n))
    }

    private static func formatBytesNum(_ num: Double) -> String {
        guard !num.isNaN else { return "—" }
        if num < 1024 { return "\(Int(num)) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var v = num / 1024
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        let decimals = v >= 100 ? 0 : 1
        return String(format: "%.\(decimals)f %@", v, units[i])
    }

    /// Format a millisecond duration.
    static func formatMs(_ ms: Double?) -> String {
        guard let ms, !ms.isNaN else { return "—" }
        if ms < 1000 { return "\(Int(ms)) ms" }
        return String(format: "%.1f s", ms / 1000)
    }

    /// Collapse whitespace, trim; if longer than n, first n chars + ellipsis.
    static func truncate(_ s: String?, n: Int = 100) -> String {
        guard let s, !s.isEmpty else { return "" }
        let collapsed = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count > n {
            let end = collapsed.index(collapsed.startIndex, offsetBy: n)
            return String(collapsed[..<end]) + "…"
        }
        return collapsed
    }
}
