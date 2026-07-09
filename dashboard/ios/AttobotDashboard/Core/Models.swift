import Foundation

// Response types decode against RAW JSON keys (no global keyDecodingStrategy).
// Each struct maps snake_case JSON → camelCase Swift via CodingKeys so the
// untyped JSONValue dictionaries elsewhere keep the server's raw keys verbatim
// (required for faithful JsonView output). Count fields arrive as strings
// (server casts `::text`); bigint ids use Int64; omitted fields are optional.

// MARK: - Overview

struct Overview: Codable {
    var metrics: [String: JSONValue]?
    var worker: Worker?
    var byType: [NameCount]?
    var byStatus: [NameCount]?
    var agents: [OverviewAgent]?

    enum CodingKeys: String, CodingKey {
        case metrics, worker
        case byType = "by_type"
        case byStatus = "by_status"
        case agents
    }

    struct Worker: Codable {
        var startedAt: String?
        var lastSeenAt: String?
        var ageSeconds: Double?
        enum CodingKeys: String, CodingKey {
            case startedAt = "started_at"
            case lastSeenAt = "last_seen_at"
            case ageSeconds = "age_seconds"
        }
    }
}

/// by_type carries `type` + `count`; by_status carries `status` + `count`.
/// Both optional so one struct handles both.
struct NameCount: Codable, Hashable {
    var status: String?
    var type: String?
    var count: String
}

struct OverviewAgent: Codable, Hashable {
    var id: Int64
    var slug: String
    var enabled: Bool
}

// MARK: - Workflows

struct WorkflowRow: Codable, Hashable {
    var id: String
    var label: String
    var status: String
    var submittedBy: String
    var db: String?
    var updatedAt: String
    var type: String
    var agent: String?

    enum CodingKeys: String, CodingKey {
        case id, label, status
        case submittedBy = "submitted_by"
        case db
        case updatedAt = "updated_at"
        case type, agent
    }
}

struct WorkflowList: Codable {
    var rows: [WorkflowRow]
    var total: Int
    var limit: Int
    var offset: Int
}

struct InstanceNode: Codable, Hashable {
    var executionId: String
    var nodeId: String
    var nodeType: String
    var query: String?
    var resultName: String?
    var leftNode: String?
    var rightNode: String?
    var status: String?
    var result: JSONValue?

    enum CodingKeys: String, CodingKey {
        case executionId = "execution_id"
        case nodeId = "node_id"
        case nodeType = "node_type"
        case query
        case resultName = "result_name"
        case leftNode = "left_node"
        case rightNode = "right_node"
        case status, result
    }
}

struct WorkflowDetail: Codable {
    var info: [String: JSONValue]?
    var explain: String?
    var result: JSONValue?
    var nodes: [InstanceNode]?
    var currentExecutionId: String?
    var executions: [[String: JSONValue]]?

    enum CodingKeys: String, CodingKey {
        case info, explain, result, nodes
        case currentExecutionId = "current_execution_id"
        case executions
    }
}

// MARK: - Agents

struct AgentRow: Codable, Hashable {
    var id: Int64
    var slug: String
    var soul: String
    var enabled: Bool
    var maxTurn: Int
    var modelId: Int
    var modelName: String?
    var apiBase: String?
    var temperature: String?
    var reasoningEffort: String?
    var contextTokens: Int?
    var multimodalSupport: Bool?
    var createdAt: String
    var updatedAt: String
    var msgCount: String
    var memCount: String
    var wfCount: String

    enum CodingKeys: String, CodingKey {
        case id, slug, soul, enabled
        case maxTurn = "max_turn"
        case modelId = "model_id"
        case modelName = "model_name"
        case apiBase = "api_base"
        case temperature
        case reasoningEffort = "reasoning_effort"
        case contextTokens = "context_tokens"
        case multimodalSupport = "multimodal_support"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case msgCount = "msg_count"
        case memCount = "mem_count"
        case wfCount = "wf_count"
    }
}

// MARK: - Messages

struct MessageRow: Codable, Hashable {
    var id: Int64
    var agentId: Int64
    var role: String
    var content: String
    var payload: JSONValue?
    var channel: String?
    var chatId: String?
    var toolCallId: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case agentId = "agent_id"
        case role, content, payload, channel
        case chatId = "chat_id"
        case toolCallId = "tool_call_id"
        case createdAt = "created_at"
    }
}

// MARK: - Memory

struct MemoryRow: Codable, Hashable {
    var id: Int64
    var agentId: Int64
    var content: String?
    var payload: JSONValue?
    var enabled: Bool?
    var createdAt: String?
    var updatedAt: String?
    var sourceMessageIds: [Int64]?

    enum CodingKeys: String, CodingKey {
        case id
        case agentId = "agent_id"
        case content, payload, enabled
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case sourceMessageIds = "source_message_ids"
    }
}

// MARK: - Users

struct UserRow: Codable, Hashable {
    var id: Int64
    var channel: String?
    var externalId: String?
    var username: String?
    var displayName: String?
    var tier: String?
    var payload: JSONValue?
    var createdAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, channel
        case externalId = "external_id"
        case username
        case displayName = "display_name"
        case tier, payload
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Lifecycle

struct LifecycleRow: Codable, Hashable {
    var id: Int64
    var agentId: Int64?
    var event: String?
    var detail: JSONValue?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case agentId = "agent_id"
        case event, detail
        case createdAt = "created_at"
    }
}

// MARK: - Config

struct ConfigRow: Codable, Hashable {
    var agentId: Int64
    var key: String
    var value: JSONValue?
    var secret: Bool
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case key, value, secret
        case updatedAt = "updated_at"
    }
}

// MARK: - Blobs

struct BlobRow: Codable, Hashable {
    var agentId: Int64?
    var hash: String?
    var size: Int64?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case hash, size
        case createdAt = "created_at"
    }
}

// MARK: - Generic list wrapper

struct RowList<T: Decodable>: Decodable {
    var rows: [T]
}
