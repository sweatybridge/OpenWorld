import Foundation

/// Verbatim port of dashboard/mobile/src/lib/label.ts. Parses attobot:* durable
/// instance labels into a friendly type + context. (Not heavily used by the
/// current screens, but kept for parity with the web/RN clients.)

enum LabelType: String {
    case loop, inbox, cron, send, tool, typing, attobot, other
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
        .attobot: ("🤖", "attobot"),
        .other: ("•", "workflow"),
    ]

    static func icon(for type: String) -> String {
        if let t = LabelType(rawValue: type), let m = meta[t] { return m.icon }
        return meta[.other]!.icon
    }

    static func parse(_ raw: String) -> ParsedLabel {
        let parts = raw.components(separatedBy: ":")
        guard parts.first == "attobot", parts.count >= 2 else {
            return ParsedLabel(type: .other, agent: nil, ref: nil, friendly: raw)
        }
        // attobot:<agent>:(loop|inbox)
        if parts.count == 3, let t = LabelType(rawValue: parts[2]), t == .loop || t == .inbox {
            let label = meta[t]!.label
            return ParsedLabel(type: t, agent: parts[1], ref: nil, friendly: "\(parts[1]) \(label)")
        }
        // attobot:<agent>:cron:<name>
        if parts.count >= 4, parts[2] == "cron" {
            let name = parts[3...].joined(separator: ":")
            return ParsedLabel(type: .cron, agent: parts[1], ref: name, friendly: "\(parts[1]) cron \"\(name)\"")
        }
        // attobot:send:<id>
        if parts[1] == "send", parts.count >= 3 {
            return ParsedLabel(type: .send, agent: nil, ref: parts[2], friendly: "send msg #\(parts[2])")
        }
        // attobot:typing:<id>
        if parts[1] == "typing", parts.count >= 3 {
            return ParsedLabel(type: .typing, agent: nil, ref: parts[2], friendly: "typing #\(parts[2])")
        }
        // attobot:tool:<msg>:<tc>
        if parts[1] == "tool", parts.count >= 4 {
            return ParsedLabel(type: .tool, agent: nil, ref: parts[2...].joined(separator: ":"), friendly: "tool msg #\(parts[2])")
        }
        return ParsedLabel(type: .attobot, agent: nil, ref: nil, friendly: raw)
    }
}
