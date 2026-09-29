//
//  RestClient.swift
//  hermes-native-app
//
//  Async REST client for the dashboard HTTP surface (hermes_cli/web_server.py).
//  Every request carries X-Hermes-Session-Token. Each route below was verified
//  against web/src/lib/api.ts or web_server.py route decorators.
//

import Foundation

public enum RestError: Error, LocalizedError, Sendable {
    case http(status: Int, body: String)
    case invalidJSON
    case unexpectedShape(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            let trimmed = body.prefix(300)
            return "HTTP \(status): \(trimmed)"
        case .invalidJSON: return "Backend returned invalid JSON"
        case .unexpectedShape(let detail): return "Unexpected response shape: \(detail)"
        }
    }
}

public struct RestClient: Sendable {
    public let baseURL: URL
    public let token: String
    private let urlSession: URLSession

    public init(baseURL: URL, token: String, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.urlSession = urlSession
    }

    public init(connection: BackendConnection, urlSession: URLSession = .shared) {
        self.init(baseURL: connection.baseURL, token: connection.token, urlSession: urlSession)
    }

    // MARK: Core

    private func makeRequest(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: JSONValue?
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw RestError.unexpectedShape("bad base URL")
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw RestError.unexpectedShape("bad URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.encoded()
        }
        request.timeoutInterval = 60
        return request
    }

    @discardableResult
    private func json(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: JSONValue? = nil
    ) async throws -> JSONValue {
        let request = try makeRequest(method: method, path: path, query: query, body: body)
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw RestError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let value = JSONValue.decode(data) else { throw RestError.invalidJSON }
        return value
    }

    // MARK: Status / gateway / update

    /// GET /api/status
    public func status() async throws -> StatusResponse {
        StatusResponse(json: try await json("GET", "/api/status"))
    }

    /// POST /api/gateway/restart
    public func restartGateway() async throws -> JSONValue {
        try await json("POST", "/api/gateway/restart")
    }

    /// GET /api/hermes/update/check[?force=true]
    public func checkUpdate(force: Bool = false) async throws -> UpdateCheck {
        let query = force ? [URLQueryItem(name: "force", value: "true")] : []
        return UpdateCheck(json: try await json("GET", "/api/hermes/update/check", query: query))
    }

    /// POST /api/hermes/update — backgrounded action; poll with actionStatus(name:).
    public func runUpdate() async throws -> JSONValue {
        try await json("POST", "/api/hermes/update")
    }

    /// GET /api/actions/{name}/status?lines= — progress of backgrounded actions
    /// (name "update" for hermes update).
    public func actionStatus(name: String, lines: Int = 200) async throws -> JSONValue {
        try await json(
            "GET", "/api/actions/\(name)/status",
            query: [URLQueryItem(name: "lines", value: String(lines))]
        )
    }

    // MARK: Sessions

    /// GET /api/sessions?limit&offset&archived&order
    /// archived: "exclude" (default) | "include" | "only"; order: "created" | "recent".
    public func sessions(
        limit: Int = 40,
        offset: Int = 0,
        archived: String = "exclude",
        order: String = "recent",
        minMessages: Int = 0
    ) async throws -> SessionListPage {
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "archived", value: archived),
            URLQueryItem(name: "order", value: order),
        ]
        if minMessages > 0 {
            query.append(URLQueryItem(name: "min_messages", value: String(minMessages)))
        }
        return SessionListPage(json: try await json("GET", "/api/sessions", query: query))
    }

    /// GET /api/sessions/search?q=  (FTS5)
    public func searchSessions(query text: String) async throws -> [SessionSearchResult] {
        let result = try await json(
            "GET", "/api/sessions/search",
            query: [URLQueryItem(name: "q", value: text)]
        )
        return (result["results"].arrayValue ?? []).compactMap(SessionSearchResult.init(json:))
    }

    /// GET /api/sessions/{id} — resolves exact ids and unique prefixes.
    public func session(id: String) async throws -> SessionSummary {
        guard let summary = SessionSummary(json: try await json("GET", "/api/sessions/\(id)")) else {
            throw RestError.unexpectedShape("session detail missing id")
        }
        return summary
    }

    /// PATCH /api/sessions/{id} {title?, archived?} — rename and/or (un)archive.
    public func updateSession(id: String, title: String? = nil, archived: Bool? = nil) async throws {
        var body: [String: JSONValue] = [:]
        if let title { body["title"] = .string(title) }
        if let archived { body["archived"] = .bool(archived) }
        _ = try await json("PATCH", "/api/sessions/\(id)", body: .object(body))
    }

    /// DELETE /api/sessions/{id} — idempotent (already-absent rows succeed).
    public func deleteSession(id: String) async throws {
        _ = try await json("DELETE", "/api/sessions/\(id)")
    }

    /// GET /api/sessions/{id}/messages — raw stored transcript
    /// (content is string OR structured blocks; includes tool_calls/reasoning).
    public func sessionMessages(id: String) async throws -> [SessionMessage] {
        let result = try await json("GET", "/api/sessions/\(id)/messages")
        return (result["messages"].arrayValue ?? []).map(SessionMessage.init(json:))
    }

    // MARK: Config

    /// GET /api/config
    public func config() async throws -> ConfigPayload {
        ConfigPayload(json: try await json("GET", "/api/config"))
    }

    /// PUT /api/config {config: {...}} — full document write.
    public func saveConfig(_ config: JSONValue) async throws {
        _ = try await json("PUT", "/api/config", body: .object(["config": config]))
    }

    /// GET /api/config/schema — {fields, category_order}.
    public func configSchema() async throws -> JSONValue {
        try await json("GET", "/api/config/schema")
    }

    // MARK: Env / provider credentials

    /// GET /api/env — key -> metadata (values always redacted).
    public func envVars() async throws -> [EnvVarInfo] {
        let result = try await json("GET", "/api/env")
        guard let dict = result.objectValue else { return [] }
        return dict.map { EnvVarInfo(key: $0.key, json: $0.value) }
            .sorted { $0.key < $1.key }
    }

    /// PUT /api/env {key, value}
    public func setEnvVar(key: String, value: String) async throws {
        _ = try await json("PUT", "/api/env", body: ["key": .string(key), "value": .string(value)])
    }

    /// DELETE /api/env {key}
    public func deleteEnvVar(key: String) async throws {
        _ = try await json("DELETE", "/api/env", body: ["key": .string(key)])
    }

    /// POST /api/providers/validate {key, value, api_key} — reachability probe.
    public func validateProviderCredential(key: String, value: String, apiKey: String = "") async throws -> JSONValue {
        try await json("POST", "/api/providers/validate", body: [
            "key": .string(key), "value": .string(value), "api_key": .string(apiKey),
        ])
    }

    // MARK: Provider OAuth

    /// GET /api/providers/oauth
    public func oauthProviders() async throws -> [ProviderOAuthInfo] {
        let result = try await json("GET", "/api/providers/oauth")
        return (result["providers"].arrayValue ?? []).compactMap(ProviderOAuthInfo.init(json:))
    }

    /// POST /api/providers/oauth/{id}/start — pkce {auth_url} | device_code
    /// {user_code, verification_url, poll_interval}.
    public func oauthStart(providerID: String) async throws -> OAuthStartInfo {
        let result = try await json("POST", "/api/providers/oauth/\(providerID)/start", body: .object([:]))
        guard let info = OAuthStartInfo(json: result) else {
            throw RestError.unexpectedShape("oauth start missing session_id")
        }
        return info
    }

    /// POST /api/providers/oauth/{id}/submit {session_id, code}
    public func oauthSubmit(providerID: String, sessionID: String, code: String) async throws -> JSONValue {
        try await json("POST", "/api/providers/oauth/\(providerID)/submit", body: [
            "session_id": .string(sessionID), "code": .string(code),
        ])
    }

    /// GET /api/providers/oauth/{id}/poll/{sid}
    public func oauthPoll(providerID: String, sessionID: String) async throws -> OAuthPollInfo {
        OAuthPollInfo(json: try await json("GET", "/api/providers/oauth/\(providerID)/poll/\(sessionID)"))
    }

    /// DELETE /api/providers/oauth/{id} — disconnect.
    public func oauthDisconnect(providerID: String) async throws {
        _ = try await json("DELETE", "/api/providers/oauth/\(providerID)")
    }

    // MARK: Model

    /// GET /api/model/info
    public func modelInfo() async throws -> ModelInfo {
        ModelInfo(json: try await json("GET", "/api/model/info"))
    }

    /// GET /api/model/options[?refresh=1]
    public func modelOptions(refresh: Bool = false) async throws -> ModelOptions {
        let query = refresh ? [URLQueryItem(name: "refresh", value: "1")] : []
        return ModelOptions(json: try await json("GET", "/api/model/options", query: query))
    }

    /// POST /api/model/set {scope: "main"|"auxiliary", provider, model, api_key?}
    public func setModel(scope: String = "main", provider: String, model: String, apiKey: String? = nil) async throws -> JSONValue {
        var body: [String: JSONValue] = [
            "scope": .string(scope), "provider": .string(provider), "model": .string(model),
        ]
        if let apiKey { body["api_key"] = .string(apiKey) }
        return try await json("POST", "/api/model/set", body: .object(body))
    }

    // MARK: Cron

    /// GET /api/cron/jobs
    public func cronJobs() async throws -> [CronJob] {
        let result = try await json("GET", "/api/cron/jobs")
        return (result.arrayValue ?? []).compactMap(CronJob.init(json:))
    }

    /// POST /api/cron/jobs — body: {name?, prompt?, schedule?, deliver?, model?, …}.
    public func createCronJob(_ job: JSONValue) async throws -> CronJob? {
        CronJob(json: try await json("POST", "/api/cron/jobs", body: job))
    }

    /// PUT /api/cron/jobs/{id} {updates: {...}}
    public func updateCronJob(id: String, updates: JSONValue) async throws -> CronJob? {
        CronJob(json: try await json("PUT", "/api/cron/jobs/\(id)", body: .object(["updates": updates])))
    }

    /// DELETE /api/cron/jobs/{id}
    public func deleteCronJob(id: String) async throws {
        _ = try await json("DELETE", "/api/cron/jobs/\(id)")
    }

    /// POST /api/cron/jobs/{id}/pause
    public func pauseCronJob(id: String) async throws -> CronJob? {
        CronJob(json: try await json("POST", "/api/cron/jobs/\(id)/pause"))
    }

    /// POST /api/cron/jobs/{id}/resume
    public func resumeCronJob(id: String) async throws -> CronJob? {
        CronJob(json: try await json("POST", "/api/cron/jobs/\(id)/resume"))
    }

    /// POST /api/cron/jobs/{id}/trigger — run now.
    public func triggerCronJob(id: String) async throws -> CronJob? {
        CronJob(json: try await json("POST", "/api/cron/jobs/\(id)/trigger"))
    }

    // MARK: Analytics

    /// GET /api/analytics/usage?days=
    public func analyticsUsage(days: Int = 30) async throws -> AnalyticsUsage {
        AnalyticsUsage(json: try await json(
            "GET", "/api/analytics/usage",
            query: [URLQueryItem(name: "days", value: String(max(1, days)))]
        ))
    }

    // MARK: Skills

    /// GET /api/skills
    public func skills() async throws -> [Skill] {
        let result = try await json("GET", "/api/skills")
        return (result.arrayValue ?? []).compactMap(Skill.init(json:))
    }

    /// PUT /api/skills/toggle {name, enabled}
    public func toggleSkill(name: String, enabled: Bool) async throws {
        _ = try await json("PUT", "/api/skills/toggle", body: [
            "name": .string(name), "enabled": .bool(enabled),
        ])
    }

    /// GET /api/skills/content?name=
    public func skillContent(name: String) async throws -> JSONValue {
        try await json("GET", "/api/skills/content", query: [URLQueryItem(name: "name", value: name)])
    }

    // MARK: Memory / learning

    /// GET /api/memory — provider status only (no curated-item list exists server-side).
    public func memoryStatus() async throws -> MemoryStatus {
        MemoryStatus(json: try await json("GET", "/api/memory"))
    }

    /// GET /api/learning/graph — memory/skill node graph (raw; node ids feed learningNode()).
    public func learningGraph() async throws -> JSONValue {
        try await json("GET", "/api/learning/graph")
    }

    /// GET /api/learning/node?id=
    public func learningNode(id: String) async throws -> MemoryItem? {
        MemoryItem(json: try await json(
            "GET", "/api/learning/node",
            query: [URLQueryItem(name: "id", value: id)]
        ))
    }

    /// DELETE /api/learning/node {id} — "Forget".
    public func deleteLearningNode(id: String) async throws {
        _ = try await json("DELETE", "/api/learning/node", body: ["id": .string(id)])
    }

    /// PUT /api/learning/node {id, content}
    public func editLearningNode(id: String, content: String) async throws {
        _ = try await json("PUT", "/api/learning/node", body: [
            "id": .string(id), "content": .string(content),
        ])
    }

    // MARK: Files (SOUL.md / AGENTS.md spot editor)

    /// GET /api/fs/read-text?path= — UTF-8 text read (size-capped server-side).
    public func readTextFile(path: String) async throws -> TextFileContent {
        TextFileContent(json: try await json(
            "GET", "/api/fs/read-text",
            query: [URLQueryItem(name: "path", value: path)]
        ))
    }

    /// POST /api/fs/write-text {path, content} — atomic replace; parent dir must exist.
    public func writeTextFile(path: String, content: String) async throws {
        _ = try await json("POST", "/api/fs/write-text", body: [
            "path": .string(path), "content": .string(content),
        ])
    }

    // MARK: Toolsets / MCP / messaging (Skills view backing)

    /// GET /api/tools/toolsets
    public func toolsets() async throws -> [ToolsetInfo] {
        let result = try await json("GET", "/api/tools/toolsets")
        return (result.arrayValue ?? []).compactMap(ToolsetInfo.init(json:))
    }

    /// PUT /api/tools/toolsets/{name} {enabled}
    public func toggleToolset(name: String, enabled: Bool) async throws {
        _ = try await json("PUT", "/api/tools/toolsets/\(name)", body: ["enabled": .bool(enabled)])
    }

    /// GET /api/mcp/servers
    public func mcpServers() async throws -> JSONValue {
        try await json("GET", "/api/mcp/servers")
    }

    /// PUT /api/mcp/servers/{name}/enabled {enabled}
    public func setMcpServerEnabled(name: String, enabled: Bool) async throws {
        _ = try await json("PUT", "/api/mcp/servers/\(name)/enabled", body: ["enabled": .bool(enabled)])
    }

    /// GET /api/messaging/platforms
    public func messagingPlatforms() async throws -> [MessagingPlatform] {
        let result = try await json("GET", "/api/messaging/platforms")
        return (result["platforms"].arrayValue ?? []).compactMap(MessagingPlatform.init(json:))
    }
}
