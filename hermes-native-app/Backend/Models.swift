//
//  Models.swift
//  hermes-native-app
//
//  Defensive Codable-ish models for the hermes backend (tui_gateway + web_server).
//  Everything decodes through JSONValue so shape drift can never crash the app;
//  unknown event types fall through to `.unknown`.
//

import Foundation

// MARK: - JSONValue

/// Lenient JSON representation used as the wire type for RPC params/results
/// and as the substrate every model decodes from.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Emit integral numbers without a trailing ".0" (server-side int params).
            if value.rounded() == value, value.magnitude < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var dict: [String: JSONValue] = [:]
        for (key, value) in elements { dict[key] = value }
        self = .object(dict)
    }
}

public extension JSONValue {
    subscript(key: String) -> JSONValue {
        if case .object(let dict) = self { return dict[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSONValue {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return .null
    }

    var isNull: Bool { if case .null = self { return true }; return false }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// String coercion: numbers/bools stringify, everything else is nil.
    var coercedString: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value.rounded() == value ? String(Int64(value)) : String(value)
        case .bool(let value): return String(value)
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    var int: Int? {
        guard let value = double, value.magnitude < Double(Int.max) else { return nil }
        return Int(value)
    }

    var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value):
            switch value.lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off", "": return false
            default: return nil
            }
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let dict) = self { return dict }
        return nil
    }

    var stringArray: [String]? {
        arrayValue?.compactMap { $0.coercedString }
    }

    /// First non-null value among alias keys (e.g. tool_id|id, args|arguments|input).
    func first(_ keys: [String]) -> JSONValue {
        for key in keys {
            let value = self[key]
            if !value.isNull { return value }
        }
        return .null
    }

    static func decode(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data("null".utf8)
    }

    func encodedString() -> String {
        String(data: encoded(), encoding: .utf8) ?? "null"
    }
}

// MARK: - Sessions (REST)

/// One row from `GET /api/sessions` (`list_sessions_rich`).
public struct SessionSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public var title: String
    public var preview: String
    public var source: String?
    public var model: String?
    public var cwd: String?
    public var startedAt: Double
    public var endedAt: Double?
    public var lastActive: Double
    public var isActive: Bool
    public var archived: Bool
    public var messageCount: Int
    public var toolCallCount: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var parentSessionID: String?
    public var profile: String?

    public init?(json: JSONValue) {
        guard let id = json["id"].coercedString, !id.isEmpty else { return nil }
        self.id = id
        title = json["title"].string ?? ""
        preview = json["preview"].string ?? ""
        source = json["source"].string
        model = json["model"].string
        cwd = json["cwd"].string
        startedAt = json["started_at"].double ?? 0
        endedAt = json["ended_at"].double
        lastActive = json["last_active"].double ?? startedAt
        isActive = json["is_active"].bool ?? false
        archived = json["archived"].bool ?? false
        messageCount = json["message_count"].int ?? 0
        toolCallCount = json["tool_call_count"].int ?? 0
        inputTokens = json["input_tokens"].int ?? 0
        outputTokens = json["output_tokens"].int ?? 0
        parentSessionID = json["parent_session_id"].string
        profile = json["profile"].string
    }
}

/// `GET /api/sessions` envelope.
public struct SessionListPage: Sendable {
    public var sessions: [SessionSummary]
    public var total: Int
    public var limit: Int
    public var offset: Int

    public init(json: JSONValue) {
        sessions = (json["sessions"].arrayValue ?? []).compactMap(SessionSummary.init(json:))
        total = json["total"].int ?? sessions.count
        limit = json["limit"].int ?? sessions.count
        offset = json["offset"].int ?? 0
    }
}

/// One row from `GET /api/sessions/search?q=`.
public struct SessionSearchResult: Identifiable, Sendable {
    public var id: String { sessionID + snippet }
    public let sessionID: String
    public var snippet: String
    public var role: String?
    public var source: String?
    public var model: String?
    public var sessionStarted: Double?

    public init?(json: JSONValue) {
        guard let sid = json["session_id"].coercedString else { return nil }
        sessionID = sid
        snippet = json["snippet"].string ?? ""
        role = json["role"].string
        source = json["source"].string
        model = json["model"].string
        sessionStarted = json["session_started"].double
    }
}

// MARK: - Stored messages (REST transcript)

/// Message content is either a plain string or structured blocks
/// (multimodal turns store `[{type:"text",...},{type:"image_url",...}]`).
public enum MessageContent: Sendable, Equatable {
    case text(String)
    case blocks([JSONValue])
    case empty

    public init(json: JSONValue) {
        switch json {
        case .string(let value): self = .text(value)
        case .array(let items): self = .blocks(items)
        case .null: self = .empty
        case .object: self = .blocks([json])
        default: self = .text(json.coercedString ?? "")
        }
    }

    /// Flattened display text; images/audio render as placeholders.
    public var displayText: String {
        switch self {
        case .text(let value): return value
        case .empty: return ""
        case .blocks(let blocks):
            var parts: [String] = []
            for block in blocks {
                let kind = block["type"].string ?? ""
                switch kind {
                case "text", "input_text", "output_text":
                    let text = block["text"].string ?? block["content"].string ?? ""
                    if !text.isEmpty { parts.append(text) }
                case "image_url", "input_image", "image":
                    parts.append("[image]")
                case "input_audio", "audio":
                    parts.append("[audio]")
                default:
                    if let text = block["text"].string, !text.isEmpty {
                        parts.append(text)
                    } else if let str = block.string {
                        parts.append(str)
                    } else if !kind.isEmpty {
                        parts.append("[\(kind)]")
                    }
                }
            }
            return parts.joined(separator: "\n")
        }
    }
}

/// One recorded tool call on a stored assistant message.
public struct ToolCallRecord: Sendable, Equatable {
    public let id: String
    public let name: String
    /// Raw JSON string as stored (`function.arguments`).
    public let argumentsJSON: String
    public var arguments: JSONValue {
        JSONValue.decode(Data(argumentsJSON.utf8)) ?? .null
    }

    public init?(json: JSONValue) {
        let function = json["function"]
        guard let name = function["name"].string ?? json["name"].string else { return nil }
        self.name = name
        id = json["id"].coercedString ?? ""
        if let raw = function["arguments"].string {
            argumentsJSON = raw
        } else if !function["arguments"].isNull {
            argumentsJSON = function["arguments"].encodedString()
        } else {
            argumentsJSON = "{}"
        }
    }
}

/// One row from `GET /api/sessions/{id}/messages` (raw DB row, lenient).
public struct SessionMessage: Sendable {
    public let role: String
    public let content: MessageContent
    public let reasoning: String?
    public let toolCalls: [ToolCallRecord]
    public let toolName: String?
    public let toolCallID: String?
    public let timestamp: Double?
    public let raw: JSONValue

    public init(json: JSONValue) {
        raw = json
        role = json["role"].string ?? "assistant"
        content = MessageContent(json: json["content"])
        reasoning = json.first(["reasoning", "reasoning_content"]).string
        toolCalls = (json["tool_calls"].arrayValue ?? []).compactMap(ToolCallRecord.init(json:))
        toolName = json["tool_name"].string
        toolCallID = json["tool_call_id"].string
        timestamp = json.first(["timestamp", "created_at"]).double
    }
}

// MARK: - Usage / runtime info

/// Usage block from `session.info` events, `message.complete`, `session.usage` RPC.
public struct UsageStats: Sendable, Equatable {
    public var model: String?
    public var input: Int
    public var output: Int
    public var reasoning: Int
    public var total: Int
    public var calls: Int
    public var contextUsed: Int?
    public var contextMax: Int?
    public var contextPercent: Int?
    public var compressions: Int
    public var activeSubagents: Int
    public var costUSD: Double?
    public var costStatus: String?

    public init(json: JSONValue) {
        model = json["model"].string
        input = json.first(["input", "prompt"]).int ?? 0
        output = json.first(["output", "completion"]).int ?? 0
        reasoning = json["reasoning"].int ?? 0
        total = json["total"].int ?? (input + output)
        calls = json["calls"].int ?? 0
        contextUsed = json["context_used"].int
        contextMax = json["context_max"].int
        contextPercent = json["context_percent"].int
        compressions = json["compressions"].int ?? 0
        activeSubagents = json["active_subagents"].int ?? 0
        costUSD = json["cost_usd"].double
        costStatus = json["cost_status"].string
    }
}

/// `info` payload from session.create/resume results and `session.info` events.
public struct SessionRuntimeInfo: Sendable {
    public var model: String
    public var provider: String?
    public var reasoningEffort: String?
    public var serviceTier: String?
    public var fast: Bool
    public var yolo: Bool
    public var cwd: String?
    public var branch: String?
    public var personality: String?
    public var running: Bool
    public var title: String?
    /// Gate on >= 2 (Electron desktop contract). 0 when absent.
    public var desktopContract: Int
    public var version: String?
    public var releaseDate: String?
    public var usage: UsageStats?
    public var profileName: String?
    public var lazy: Bool
    public var credentialWarning: String?
    /// toolset name -> tool names
    public var toolsByToolset: [String: [String]]
    public var skills: JSONValue
    public var mcpServers: JSONValue
    public var raw: JSONValue

    public init(json: JSONValue) {
        raw = json
        model = json["model"].string ?? ""
        provider = json["provider"].string
        reasoningEffort = json["reasoning_effort"].string
        serviceTier = json["service_tier"].string
        fast = json["fast"].bool ?? false
        yolo = json["yolo"].bool ?? false
        cwd = json["cwd"].string
        branch = json["branch"].string
        personality = json["personality"].string
        running = json["running"].bool ?? false
        title = json["title"].string
        desktopContract = json["desktop_contract"].int ?? 0
        version = json["version"].string
        releaseDate = json["release_date"].string
        usage = json["usage"].isNull ? nil : UsageStats(json: json["usage"])
        profileName = json["profile_name"].string
        lazy = json["lazy"].bool ?? false
        credentialWarning = json["credential_warning"].string
        var tools: [String: [String]] = [:]
        if let dict = json["tools"].objectValue {
            for (toolset, names) in dict {
                tools[toolset] = names.stringArray ?? []
            }
        }
        toolsByToolset = tools
        skills = json["skills"]
        mcpServers = json["mcp_servers"]
    }
}

// MARK: - Gateway events

/// `tool.start` payload. `tool_id` aliases `id`; args text only in verbose mode.
public struct ToolStartPayload: Sendable {
    public let toolID: String
    public let name: String
    public let context: String?
    public let argsText: String?
    public let todos: [JSONValue]

    public init(json: JSONValue) {
        toolID = json.first(["tool_id", "id"]).coercedString ?? UUID().uuidString
        name = json["name"].string ?? "tool"
        context = json["context"].string
        argsText = json["args_text"].string
        todos = json["todos"].arrayValue ?? []
    }
}

/// `tool.complete` payload. `args` aliases `arguments`/`input`.
public struct ToolCompletePayload: Sendable {
    public let toolID: String
    public let name: String
    public let args: JSONValue
    public let result: JSONValue
    public let resultText: String?
    public let summary: String?
    public let inlineDiff: String?
    public let durationSeconds: Double?
    public let error: String?
    public let todos: [JSONValue]?

    public init(json: JSONValue) {
        toolID = json.first(["tool_id", "id"]).coercedString ?? ""
        name = json["name"].string ?? "tool"
        args = json.first(["args", "arguments", "input"])
        result = json["result"]
        resultText = json["result_text"].string
        summary = json["summary"].string
        inlineDiff = json["inline_diff"].string
        durationSeconds = json["duration_s"].double
        error = json["error"].string
        todos = json["todos"].arrayValue
    }
}

/// `approval.request` — answered with `approval.respond {session_id, choice}`
/// (choice keyed to the session, not a request id).
public struct ApprovalRequestPayload: Sendable {
    public let command: String
    public let description: String
    public let allowPermanent: Bool
    public let requestID: String?

    public init(json: JSONValue) {
        command = json["command"].string ?? ""
        description = json["description"].string ?? ""
        allowPermanent = json["allow_permanent"].bool ?? false
        requestID = json["request_id"].string
    }
}

/// `clarify.request` — answered with `clarify.respond {request_id, answer}`.
public struct ClarifyRequestPayload: Sendable {
    public let requestID: String
    public let question: String
    public let choices: [String]?

    public init(json: JSONValue) {
        requestID = json["request_id"].string ?? ""
        question = json["question"].string ?? ""
        choices = json["choices"].stringArray
    }
}

/// `sudo.request` — answered with `sudo.respond {request_id, password}` (120 s window).
public struct SudoRequestPayload: Sendable {
    public let requestID: String
    public init(json: JSONValue) { requestID = json["request_id"].string ?? "" }
}

/// `secret.request` — answered with `secret.respond {request_id, value}`.
public struct SecretRequestPayload: Sendable {
    public let requestID: String
    public let prompt: String
    public let envVar: String

    public init(json: JSONValue) {
        requestID = json["request_id"].string ?? ""
        prompt = json["prompt"].string ?? ""
        envVar = json["env_var"].string ?? ""
    }
}

/// `terminal.read.request` — answered with `terminal.read.respond {request_id, text}` (30 s window).
public struct TerminalReadRequestPayload: Sendable {
    public let requestID: String
    public let start: Int?
    public let count: Int?

    public init(json: JSONValue) {
        requestID = json["request_id"].string ?? ""
        start = json["start"].int
        count = json["count"].int
    }
}

public enum SubagentPhase: String, Sendable {
    case spawnRequested = "spawn_requested"
    case start, thinking, tool, progress, complete
}

/// Payload for `subagent.*` events.
public struct SubagentEventInfo: Sendable {
    public let subagentID: String?
    public let goal: String
    public let status: String?
    public let taskIndex: Int
    public let taskCount: Int?
    public let iteration: Int?
    public let toolName: String?
    public let toolPreview: String?
    public let text: String?
    public let summary: String?
    public let model: String?
    public let parentID: String?
    public let depth: Int?
    public let toolCount: Int?
    public let durationSeconds: Double?

    public init(json: JSONValue) {
        subagentID = json["subagent_id"].coercedString
        goal = json["goal"].string ?? ""
        status = json["status"].string
        taskIndex = json["task_index"].int ?? 0
        taskCount = json["task_count"].int
        iteration = json["iteration"].int
        toolName = json["tool_name"].string
        toolPreview = json["tool_preview"].string
        text = json["text"].string
        summary = json["summary"].string
        model = json["model"].string
        parentID = json["parent_id"].string
        depth = json["depth"].int
        toolCount = json["tool_count"].int
        durationSeconds = json["duration_seconds"].double
    }
}

/// Decoded gateway event. `type`/`sessionID`/`raw` are the envelope;
/// `payload` is the typed view (`.unknown` preserves everything via `raw`).
public struct GatewayEvent: Sendable {
    public let type: String
    public let sessionID: String?
    public let raw: JSONValue
    public let payload: Payload

    public enum Payload: Sendable {
        case gatewayReady
        case sessionInfo(SessionRuntimeInfo)
        case sessionTitle(storedSessionID: String?, title: String, pending: Bool)
        case messageStart
        case messageDelta(text: String)
        case messageComplete(text: String, reasoning: String?, usage: UsageStats?, status: String)
        case thinkingDelta(text: String)
        case reasoningDelta(text: String)
        case reasoningAvailable(text: String)
        case statusUpdate(kind: String, text: String?)
        case toolStart(ToolStartPayload)
        case toolProgress(name: String?, preview: String?)
        case toolGenerating(name: String?)
        case toolComplete(ToolCompletePayload)
        case approvalRequest(ApprovalRequestPayload)
        case clarifyRequest(ClarifyRequestPayload)
        case sudoRequest(SudoRequestPayload)
        case secretRequest(SecretRequestPayload)
        case terminalReadRequest(TerminalReadRequestPayload)
        case subagent(phase: SubagentPhase, info: SubagentEventInfo)
        case error(message: String)
        /// Unrecognized type — envelope fields carry the details.
        case unknown
    }

    public init(type: String, sessionID: String?, payload json: JSONValue) {
        self.type = type
        self.sessionID = sessionID
        self.raw = json
        switch type {
        case "gateway.ready":
            payload = .gatewayReady
        case "session.info":
            payload = .sessionInfo(SessionRuntimeInfo(json: json))
        case "session.title":
            payload = .sessionTitle(
                storedSessionID: json["session_id"].string,
                title: json["title"].string ?? "",
                pending: json["pending"].bool ?? false
            )
        case "message.start":
            payload = .messageStart
        case "message.delta":
            payload = .messageDelta(text: json["text"].string ?? "")
        case "message.complete":
            payload = .messageComplete(
                text: json["text"].string ?? "",
                reasoning: json["reasoning"].string,
                usage: json["usage"].isNull ? nil : UsageStats(json: json["usage"]),
                status: json["status"].string ?? "complete"
            )
        case "thinking.delta":
            payload = .thinkingDelta(text: json["text"].string ?? "")
        case "reasoning.delta":
            payload = .reasoningDelta(text: json["text"].string ?? "")
        case "reasoning.available":
            payload = .reasoningAvailable(text: json["text"].string ?? "")
        case "status.update":
            payload = .statusUpdate(kind: json["kind"].string ?? "status", text: json["text"].string)
        case "tool.start":
            payload = .toolStart(ToolStartPayload(json: json))
        case "tool.progress":
            payload = .toolProgress(name: json["name"].string, preview: json["preview"].string)
        case "tool.generating":
            payload = .toolGenerating(name: json["name"].string)
        case "tool.complete":
            payload = .toolComplete(ToolCompletePayload(json: json))
        case "approval.request":
            payload = .approvalRequest(ApprovalRequestPayload(json: json))
        case "clarify.request":
            payload = .clarifyRequest(ClarifyRequestPayload(json: json))
        case "sudo.request":
            payload = .sudoRequest(SudoRequestPayload(json: json))
        case "secret.request":
            payload = .secretRequest(SecretRequestPayload(json: json))
        case "terminal.read.request":
            payload = .terminalReadRequest(TerminalReadRequestPayload(json: json))
        case "error":
            payload = .error(message: json["message"].string ?? "Unknown backend error")
        default:
            if type.hasPrefix("subagent."),
               let phase = SubagentPhase(rawValue: String(type.dropFirst("subagent.".count))) {
                payload = .subagent(phase: phase, info: SubagentEventInfo(json: json))
            } else {
                payload = .unknown
            }
        }
    }

    /// Parse a JSON-RPC notification `params` object ({type, session_id, payload}).
    public init?(notificationParams params: JSONValue) {
        guard let type = params["type"].string, !type.isEmpty else { return nil }
        self.init(type: type, sessionID: params["session_id"].string, payload: params["payload"])
    }
}

// MARK: - Session lifecycle RPC results

/// Replayed transcript message from session.create/resume (`_history_to_messages`).
public struct ReplayMessage: Sendable {
    public let role: String
    public let text: String
    /// Tool rows carry name + context instead of text.
    public let name: String?
    public let context: String?
    public let reasoning: String?

    public init(json: JSONValue) {
        role = json["role"].string ?? "assistant"
        text = json["text"].string ?? ""
        name = json["name"].string
        context = json["context"].string
        reasoning = json.first(["reasoning", "reasoning_content"]).string
    }
}

/// Result of `session.create` / `session.resume`.
public struct SessionOpenResult: Sendable {
    /// Per-connection live id — changes on every resume.
    public let liveSessionID: String
    /// Durable id used by REST + session.resume (`stored_session_id` on create,
    /// `resumed` on resume).
    public let storedSessionID: String?
    public let messages: [ReplayMessage]
    public let info: SessionRuntimeInfo?
    public let running: Bool
    public let status: String?
    public let inflightUser: String?
    public let inflightAssistant: String?

    public init?(json: JSONValue) {
        guard let live = json["session_id"].string, !live.isEmpty else { return nil }
        liveSessionID = live
        storedSessionID = json.first(["stored_session_id", "resumed"]).string
        messages = (json["messages"].arrayValue ?? []).map(ReplayMessage.init(json:))
        info = json["info"].isNull ? nil : SessionRuntimeInfo(json: json["info"])
        running = json["running"].bool ?? false
        status = json["status"].string
        let inflight = json["inflight"]
        inflightUser = inflight["user"].string
        inflightAssistant = inflight["assistant"].string
    }
}

// MARK: - Cron

/// One job from `/api/cron/jobs`.
public struct CronJob: Identifiable, Sendable {
    public let id: String
    public var name: String
    public var prompt: String?
    public var scheduleKind: String?
    public var scheduleExpression: String?
    public var scheduleDisplay: String?
    public var enabled: Bool
    public var state: String?
    public var deliver: String?
    public var model: String?
    public var provider: String?
    public var skills: [String]
    public var workdir: String?
    public var profile: String?
    public var lastRunAt: String?
    public var nextRunAt: String?
    public var lastStatus: String?
    public var lastError: String?
    public var raw: JSONValue

    public init?(json: JSONValue) {
        guard let id = json["id"].coercedString, !id.isEmpty else { return nil }
        self.id = id
        raw = json
        name = json["name"].string ?? ""
        prompt = json["prompt"].string
        let schedule = json["schedule"]
        scheduleKind = schedule["kind"].string
        scheduleExpression = schedule["expr"].string ?? schedule["run_at"].string
        scheduleDisplay = json["schedule_display"].string ?? schedule["display"].string
        enabled = json["enabled"].bool ?? false
        state = json["state"].string
        deliver = json["deliver"].string
        model = json["model"].string
        provider = json["provider"].string
        skills = json["skills"].stringArray ?? []
        workdir = json["workdir"].string
        profile = json.first(["profile_name", "profile"]).string
        lastRunAt = json["last_run_at"].string
        nextRunAt = json["next_run_at"].string
        lastStatus = json["last_status"].string
        lastError = json["last_error"].string
    }
}

// MARK: - Skills / memory

/// One skill from `GET /api/skills`.
public struct Skill: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public var description: String
    public var category: String
    public var enabled: Bool

    public init?(json: JSONValue) {
        guard let name = json["name"].string, !name.isEmpty else { return nil }
        self.name = name
        description = json["description"].string ?? ""
        category = json["category"].string ?? ""
        enabled = json["enabled"].bool ?? true
    }
}

/// Learning-graph node (`/api/learning/graph` + `/api/learning/node`) —
/// the closest thing the backend has to curated memory items.
public struct MemoryItem: Identifiable, Sendable {
    public let id: String
    /// "memory" or "skill".
    public var kind: String
    public var label: String
    public var content: String?

    public init?(json: JSONValue) {
        guard let id = json["id"].coercedString else { return nil }
        self.id = id
        kind = json["kind"].string ?? "memory"
        label = json["label"].string ?? ""
        content = json["content"].string
    }
}

/// `GET /api/memory` — memory provider status (Honcho/builtin), not item list.
public struct MemoryStatus: Sendable {
    public var activeProvider: String
    public var providers: [(name: String, description: String, configured: Bool)]
    public var builtinMemoryFiles: Int
    public var builtinUserFiles: Int

    public init(json: JSONValue) {
        activeProvider = json["active"].string ?? ""
        providers = (json["providers"].arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"].string else { return nil }
            return (name, entry["description"].string ?? "", entry["configured"].bool ?? false)
        }
        builtinMemoryFiles = json["builtin_files"]["memory"].int ?? 0
        builtinUserFiles = json["builtin_files"]["user"].int ?? 0
    }
}

// MARK: - Model picker

/// `GET /api/model/info`.
public struct ModelInfo: Sendable {
    public var model: String
    public var provider: String
    public var effectiveContextLength: Int
    public var supportsTools: Bool
    public var supportsVision: Bool
    public var supportsReasoning: Bool
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var modelFamily: String?

    public init(json: JSONValue) {
        model = json["model"].string ?? ""
        provider = json["provider"].string ?? ""
        effectiveContextLength = json["effective_context_length"].int ?? 0
        let caps = json["capabilities"]
        supportsTools = caps["supports_tools"].bool ?? false
        supportsVision = caps["supports_vision"].bool ?? false
        supportsReasoning = caps["supports_reasoning"].bool ?? false
        contextWindow = caps["context_window"].int
        maxOutputTokens = caps["max_output_tokens"].int
        modelFamily = caps["model_family"].string
    }
}

/// Provider row inside `GET /api/model/options`.
public struct ModelProviderOption: Identifiable, Sendable {
    public var id: String { slug }
    public let slug: String
    public var name: String
    public var models: [String]
    public var totalModels: Int?
    public var isCurrent: Bool
    public var authenticated: Bool
    public var warning: String?
    public var authType: String?
    public var keyEnv: String?

    public init?(json: JSONValue) {
        guard let slug = json["slug"].string else { return nil }
        self.slug = slug
        name = json["name"].string ?? slug
        models = json["models"].stringArray ?? []
        totalModels = json["total_models"].int
        isCurrent = json["is_current"].bool ?? false
        authenticated = json["authenticated"].bool ?? false
        warning = json["warning"].string
        authType = json["auth_type"].string
        keyEnv = json["key_env"].string
    }
}

/// `GET /api/model/options`.
public struct ModelOptions: Sendable {
    public var currentModel: String?
    public var currentProvider: String?
    public var providers: [ModelProviderOption]

    public init(json: JSONValue) {
        currentModel = json["model"].string
        currentProvider = json["provider"].string
        providers = (json["providers"].arrayValue ?? []).compactMap(ModelProviderOption.init(json:))
    }
}

// MARK: - Provider OAuth

/// One provider from `GET /api/providers/oauth`.
public struct ProviderOAuthInfo: Identifiable, Sendable {
    public let id: String
    public var name: String
    /// "pkce" | "device_code" | "external"
    public var flow: String
    public var cliCommand: String?
    public var docsURL: String?
    public var loggedIn: Bool
    public var sourceLabel: String?
    public var tokenPreview: String?
    public var expiresAt: String?
    public var statusError: String?

    public init?(json: JSONValue) {
        guard let id = json["id"].string else { return nil }
        self.id = id
        name = json["name"].string ?? id
        flow = json["flow"].string ?? "pkce"
        cliCommand = json["cli_command"].string
        docsURL = json["docs_url"].string
        let status = json["status"]
        loggedIn = status["logged_in"].bool ?? false
        sourceLabel = status["source_label"].string
        tokenPreview = status["token_preview"].string
        expiresAt = status["expires_at"].string
        statusError = status["error"].string
    }
}

/// `POST /api/providers/oauth/{id}/start` — shape depends on `flow`.
public struct OAuthStartInfo: Sendable {
    public let sessionID: String
    public let flow: String
    public let authURL: String?
    public let userCode: String?
    public let verificationURL: String?
    public let expiresIn: Int?
    public let pollInterval: Int?

    public init?(json: JSONValue) {
        guard let sid = json["session_id"].string else { return nil }
        sessionID = sid
        flow = json["flow"].string ?? "pkce"
        authURL = json["auth_url"].string
        userCode = json["user_code"].string
        verificationURL = json["verification_url"].string
        expiresIn = json["expires_in"].int
        pollInterval = json["poll_interval"].int
    }
}

/// `GET /api/providers/oauth/{id}/poll/{sid}`.
public struct OAuthPollInfo: Sendable {
    public let sessionID: String
    /// "pending" | "approved" | "denied" | "expired" | "error"
    public let status: String
    public let errorMessage: String?

    public init(json: JSONValue) {
        sessionID = json["session_id"].string ?? ""
        status = json["status"].string ?? "pending"
        errorMessage = json["error_message"].string
    }
}

// MARK: - Config / env

/// Raw config document from `GET /api/config` (arbitrary keyed YAML mirror).
public struct ConfigPayload: Sendable {
    public var values: JSONValue
    public init(json: JSONValue) { values = json }
    public subscript(path: String...) -> JSONValue {
        var node = values
        for key in path { node = node[key] }
        return node
    }
}

/// One entry from `GET /api/env`.
public struct EnvVarInfo: Sendable {
    public let key: String
    public var isSet: Bool
    public var redactedValue: String?
    public var description: String
    public var url: String?
    public var category: String
    public var isPassword: Bool
    public var advanced: Bool
    public var channelManaged: Bool

    public init(key: String, json: JSONValue) {
        self.key = key
        isSet = json["is_set"].bool ?? false
        redactedValue = json["redacted_value"].string
        description = json["description"].string ?? ""
        url = json["url"].string
        category = json["category"].string ?? ""
        isPassword = json["is_password"].bool ?? false
        advanced = json["advanced"].bool ?? false
        channelManaged = json["channel_managed"].bool ?? false
    }
}

// MARK: - Analytics

/// `GET /api/analytics/usage?days=`.
public struct AnalyticsUsage: Sendable {
    public struct Daily: Sendable, Identifiable {
        public var id: String { day }
        public let day: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let reasoningTokens: Int
        public let estimatedCost: Double
        public let actualCost: Double
        public let sessions: Int
        public let apiCalls: Int

        public init(json: JSONValue) {
            day = json["day"].string ?? ""
            inputTokens = json["input_tokens"].int ?? 0
            outputTokens = json["output_tokens"].int ?? 0
            cacheReadTokens = json["cache_read_tokens"].int ?? 0
            reasoningTokens = json["reasoning_tokens"].int ?? 0
            estimatedCost = json["estimated_cost"].double ?? 0
            actualCost = json["actual_cost"].double ?? 0
            sessions = json["sessions"].int ?? 0
            apiCalls = json["api_calls"].int ?? 0
        }
    }

    public struct ModelRow: Sendable, Identifiable {
        public var id: String { model }
        public let model: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let estimatedCost: Double
        public let sessions: Int
        public let apiCalls: Int

        public init(json: JSONValue) {
            model = json["model"].string ?? ""
            inputTokens = json["input_tokens"].int ?? 0
            outputTokens = json["output_tokens"].int ?? 0
            estimatedCost = json["estimated_cost"].double ?? 0
            sessions = json["sessions"].int ?? 0
            apiCalls = json["api_calls"].int ?? 0
        }
    }

    public var daily: [Daily]
    public var byModel: [ModelRow]
    public var totalInput: Int
    public var totalOutput: Int
    public var totalCacheRead: Int
    public var totalReasoning: Int
    public var totalEstimatedCost: Double
    public var totalActualCost: Double
    public var totalSessions: Int
    public var totalAPICalls: Int

    public init(json: JSONValue) {
        daily = (json["daily"].arrayValue ?? []).map(Daily.init(json:))
        byModel = (json["by_model"].arrayValue ?? []).map(ModelRow.init(json:))
        let totals = json["totals"]
        totalInput = totals["total_input"].int ?? 0
        totalOutput = totals["total_output"].int ?? 0
        totalCacheRead = totals["total_cache_read"].int ?? 0
        totalReasoning = totals["total_reasoning"].int ?? 0
        totalEstimatedCost = totals["total_estimated_cost"].double ?? 0
        totalActualCost = totals["total_actual_cost"].double ?? 0
        totalSessions = totals["total_sessions"].int ?? 0
        totalAPICalls = totals["total_api_calls"].int ?? 0
    }
}

// MARK: - Update / status

/// `GET /api/hermes/update/check`.
public struct UpdateCheck: Sendable {
    public var installMethod: String
    public var currentVersion: String
    /// >=1 known count, 0 up to date, -1 behind by unknown count, nil = check failed.
    public var behind: Int?
    public var updateAvailable: Bool
    public var canApply: Bool
    public var updateCommand: String
    public var message: String?

    public init(json: JSONValue) {
        installMethod = json["install_method"].string ?? ""
        currentVersion = json["current_version"].string ?? ""
        behind = json["behind"].int
        updateAvailable = json["update_available"].bool ?? false
        canApply = json["can_apply"].bool ?? false
        updateCommand = json["update_command"].string ?? ""
        message = json["message"].string
    }
}

/// `GET /api/status`.
public struct StatusResponse: Sendable {
    public struct PlatformState: Sendable {
        public let state: String
        public let updatedAt: String?
        public let errorMessage: String?
    }

    public var version: String
    public var releaseDate: String?
    public var activeSessions: Int
    public var gatewayRunning: Bool
    public var gatewayState: String?
    public var gatewayPID: Int?
    public var gatewayExitReason: String?
    public var hermesHome: String?
    public var configPath: String?
    public var envPath: String?
    public var canUpdateHermes: Bool
    public var gatewayPlatforms: [String: PlatformState]
    public var raw: JSONValue

    public init(json: JSONValue) {
        raw = json
        version = json["version"].string ?? ""
        releaseDate = json["release_date"].string
        activeSessions = json["active_sessions"].int ?? 0
        gatewayRunning = json["gateway_running"].bool ?? false
        gatewayState = json["gateway_state"].string
        gatewayPID = json["gateway_pid"].int
        gatewayExitReason = json["gateway_exit_reason"].string
        hermesHome = json["hermes_home"].string
        configPath = json["config_path"].string
        envPath = json["env_path"].string
        canUpdateHermes = json["can_update_hermes"].bool ?? true
        var platforms: [String: PlatformState] = [:]
        if let dict = json["gateway_platforms"].objectValue {
            for (name, entry) in dict {
                platforms[name] = PlatformState(
                    state: entry["state"].string ?? "unknown",
                    updatedAt: entry["updated_at"].string,
                    errorMessage: entry["error_message"].string
                )
            }
        }
        gatewayPlatforms = platforms
    }
}

// MARK: - Toolsets / messaging (Skills view backing)

/// One row from `GET /api/tools/toolsets`.
public struct ToolsetInfo: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public var label: String
    public var description: String
    public var enabled: Bool
    public var configured: Bool
    public var tools: [String]

    public init?(json: JSONValue) {
        guard let name = json["name"].string else { return nil }
        self.name = name
        label = json["label"].string ?? name
        description = json["description"].string ?? ""
        enabled = json["enabled"].bool ?? false
        configured = json["configured"].bool ?? false
        tools = json["tools"].stringArray ?? []
    }
}

/// One platform row from `GET /api/messaging/platforms`.
public struct MessagingPlatform: Identifiable, Sendable {
    public let id: String
    public var name: String
    public var description: String
    public var enabled: Bool
    public var configured: Bool
    public var gatewayRunning: Bool
    /// "connected" | "disabled" | "not_configured" | ... (see web_server.py)
    public var state: String
    public var errorMessage: String?

    public init?(json: JSONValue) {
        guard let id = json["id"].string else { return nil }
        self.id = id
        name = json["name"].string ?? id
        description = json["description"].string ?? ""
        enabled = json["enabled"].bool ?? false
        configured = json["configured"].bool ?? false
        gatewayRunning = json["gateway_running"].bool ?? false
        state = json["state"].string ?? "unknown"
        errorMessage = json["error_message"].string
    }
}

/// `GET /api/fs/read-text` result (SOUL.md / AGENTS.md editing).
public struct TextFileContent: Sendable {
    public let path: String
    public let text: String
    public let truncated: Bool
    public let byteSize: Int
    public let binary: Bool
    public let language: String?

    public init(json: JSONValue) {
        path = json["path"].string ?? ""
        text = json["text"].string ?? ""
        truncated = json["truncated"].bool ?? false
        byteSize = json["byteSize"].int ?? 0
        binary = json["binary"].bool ?? false
        language = json["language"].string
    }
}
