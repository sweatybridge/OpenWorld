import Foundation

/// Verbatim port of dashboard/mobile/src/lib/label.ts. Parses ow:* durable
/// instance labels into a friendly type + context. (Not heavily used by the
/// current screens, but kept for parity with the web/RN clients.)

enum LabelType: String {
    case loop, inbox, cron, send, tool, typing, ow, other
}

struct ParsedLabel {
    let type: LabelType
    let agent: String?
    let ref: String?
    let friendly: String
}

enum LabelParser {
    private static let meta: [LabelType: (icon: String, label: String)] = [
        .loop: ("🔁", "agent loop"),
        .inbox: ("📥", "telegram inbox"),
        .cron: ("⏰", "cron"),
        .send: ("📤", "telegram send"),
        .tool: ("🔧", "tool call"),
        .typing: ("⌨️", "typing"),
        .ow: ("🤖", "ow"),
        .other: ("•", "workflow"),
    ]

    static func icon(for type: String) -> String {
        if let t = LabelType(rawValue: type), let m = meta[t] { return m.icon }
        return meta[.other]!.icon
    }

    static func parse(_ raw: String) -> ParsedLabel {
        let parts = raw.components(separatedBy: ":")
        guard parts.first == "ow", parts.count >= 2 else {
            return ParsedLabel(type: .other, agent: nil, ref: nil, friendly: raw)
        }
        // ow:<agent>:inbox
        if parts.count == 3, parts[2] == LabelType.inbox.rawValue {
            return ParsedLabel(type: .inbox, agent: parts[1], ref: nil, friendly: "\(parts[1]) \(meta[.inbox]!.label)")
        }
        // ow:<agent>:loop  OR  ow:<agent>:loop:<msg_id>
        if parts.count >= 3, parts[2] == LabelType.loop.rawValue {
            let ref = parts.count >= 4 ? parts[3] : nil
            let suffix = ref.map { " · msg #\($0)" } ?? ""
            return ParsedLabel(type: .loop, agent: parts[1], ref: ref, friendly: "\(parts[1]) \(meta[.loop]!.label)\(suffix)")
        }
        // ow:<agent>:cron:<name>
        if parts.count >= 4, parts[2] == "cron" {
            let name = parts[3...].joined(separator: ":")
            return ParsedLabel(type: .cron, agent: parts[1], ref: name, friendly: "\(parts[1]) cron \"\(name)\"")
        }
        // ow:send:<id>
        if parts[1] == "send", parts.count >= 3 {
            return ParsedLabel(type: .send, agent: nil, ref: parts[2], friendly: "send msg #\(parts[2])")
        }
        // ow:typing:<id>
        if parts[1] == "typing", parts.count >= 3 {
            return ParsedLabel(type: .typing, agent: nil, ref: parts[2], friendly: "typing #\(parts[2])")
        }
        // ow:tool:<msg>:<tc>
        if parts[1] == "tool", parts.count >= 4 {
            return ParsedLabel(type: .tool, agent: nil, ref: parts[2...].joined(separator: ":"), friendly: "tool msg #\(parts[2])")
        }
        return ParsedLabel(type: .ow, agent: nil, ref: nil, friendly: raw)
    }

    /// Numeric message id embedded in a traceable label (loop/send/typing/tool),
    /// or nil. Mirrors ow.parse_instance_label on the server; used to open
    /// the turn-trace view from any of these instances.
    static func messageId(from raw: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "ow:(?:[^:]+:loop|send|tool|typing):(\\d+)") else { return nil }
        let ns = raw as NSString
        guard let m = regex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges >= 2 else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }
}
