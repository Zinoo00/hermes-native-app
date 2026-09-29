//
//  SkillsHubModel.swift
//  hermes-native-app
//
//  Shared navigation + data model for the Skills (capabilities) hub.
//  The sidebar and the content container both observe the selected tab, and
//  every tab binds to data loaded here straight from the backend
//  (REST + gateway RPC) — nothing in this model is fabricated.
//

import AppKit
import Combine

/// Content tabs of the Skills hub — mirrors the design's
/// IDENTITY / LIBRARY / CONNECTIONS source list.
enum SkillsTab: CaseIterable {
    case personality, context, memory, skills, commands, messaging, tools

    var title: String {
        switch self {
        case .personality: return "Personality"
        case .context: return "Context"
        case .memory: return "Memory"
        case .skills: return "Skills"
        case .commands: return "Commands"
        case .messaging: return "Messaging"
        case .tools: return "Tools & MCP"
        }
    }

    var symbolName: String {
        switch self {
        case .personality: return "person"
        case .context: return "doc.text"
        case .memory: return "brain"
        case .skills: return "sparkles"
        case .commands: return "terminal"
        case .messaging: return "bubble.left"
        case .tools: return "wrench.adjustable"
        }
    }
}

/// Sidebar grouping (IDENTITY / LIBRARY / CONNECTIONS).
struct SkillsNavGroup {
    let label: String
    let tabs: [SkillsTab]

    static let all: [SkillsNavGroup] = [
        SkillsNavGroup(label: "Identity", tabs: [.personality, .context, .memory]),
        SkillsNavGroup(label: "Library", tabs: [.skills, .commands]),
        SkillsNavGroup(label: "Connections", tabs: [.messaging, .tools]),
    ]
}

/// One curated memory row derived from `/api/learning/graph` memory nodes.
struct SkillsMemoryEntry {
    let id: String
    let title: String
    let body: String?
    /// Section header the row files under.
    let group: String
    /// Provenance caption ("MEMORY.md · Jun 12" style).
    let provenance: String
}

/// One slash command from the `commands.catalog` RPC.
struct SkillsCommandEntry {
    let name: String
    let detail: String
}

/// One messaging platform card (REST payload + docs URL + monogram glyph).
struct SkillsMessagingCard {
    let id: String
    let name: String
    let detail: String
    let glyph: String
    let connected: Bool
    let docsURL: URL?
    /// The CLI / TUI row is this app's own gateway connection — always on.
    let alwaysOn: Bool
}

/// One MCP server row from `GET /api/mcp/servers`.
struct SkillsMcpServer {
    let name: String
    let enabled: Bool
    let transport: String
    /// nil = all of the server's tools are enabled (count unknown until connect).
    let toolCount: Int?
}

/// Shared state + loader for the Skills hub.
final class SkillsHubModel: ObservableObject {
    static let shared = SkillsHubModel()

    let store = AppEnvironment.shared.store

    @Published var tab: SkillsTab = .skills

    @Published private(set) var memoryEntries: [SkillsMemoryEntry] = []
    @Published private(set) var memoryLoaded = false
    /// Skill name -> use count, from the learning graph (feeds "used N×" chips).
    @Published private(set) var skillUseCounts: [String: Int] = [:]

    @Published private(set) var customCommands: [SkillsCommandEntry] = []
    @Published private(set) var builtinCommands: [SkillsCommandEntry] = []
    @Published private(set) var commandsLoaded = false

    @Published private(set) var messagingCards: [SkillsMessagingCard] = []
    @Published private(set) var messagingLoaded = false

    @Published private(set) var toolsets: [ToolsetInfo] = []
    @Published private(set) var mcpServers: [SkillsMcpServer] = []
    @Published private(set) var toolsLoaded = false

    private var cancellables = Set<AnyCancellable>()

    private init() {
        store.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state.isReady { self?.refreshAll() }
            }
            .store(in: &cancellables)
    }

    /// Total number of tools across enabled+disabled toolsets (header blurb).
    var totalToolsetToolCount: Int {
        toolsets.reduce(0) { $0 + $1.tools.count }
    }

    // MARK: - Refresh

    func refreshAll() {
        guard store.connectionState.isReady else { return }
        Task { await self.refreshLearning() }
        Task { await self.refreshCommands() }
        Task { await self.refreshMessaging() }
        Task { await self.refreshTools() }
        Task { await self.store.refreshSkills() }
        Task { await self.store.refreshStatus() }
    }

    /// `/api/learning/graph` → memory rows + skill use counts.
    func refreshLearning() async {
        guard let rest = store.rest else { return }
        do {
            let graph = try await rest.learningGraph()
            parseLearningGraph(graph)
        } catch {
            memoryLoaded = true // stop spinners; list stays empty
        }
    }

    private func parseLearningGraph(_ json: JSONValue) {
        var usage: [String: Int] = [:]
        var entries: [SkillsMemoryEntry] = []
        let cards = json["memory"].arrayValue ?? []

        for node in json["nodes"].arrayValue ?? [] {
            let kind = node["kind"].string ?? ""
            if kind == "skill" {
                if let name = node["label"].string ?? node["id"].coercedString {
                    usage[name] = node["useCount"].int ?? 0
                }
                continue
            }
            guard kind == "memory", let id = node["id"].coercedString else { continue }

            let source = node["memorySource"].string ?? "memory"
            // id is "memory:<source>:<index>" — index into the parallel cards array.
            var body: String?
            if let idxPart = id.split(separator: ":").last, let idx = Int(idxPart),
               idx >= 0, idx < cards.count {
                body = cards[idx]["body"].string
            }

            let file = source == "profile" ? "USER.md" : "MEMORY.md"
            var provenance = file
            if let ts = node["timestamp"].double, ts > 0 {
                provenance += " · " + Self.dateFormatter.string(from: Date(timeIntervalSince1970: ts))
            }

            // Nodes carry category == "memory" today; keep any richer category
            // the backend may grow, else group by source file.
            var group = node["category"].string ?? ""
            if group.isEmpty || group == "memory" {
                group = source == "profile" ? "User profile" : "Memory"
            }

            entries.append(SkillsMemoryEntry(
                id: id,
                title: node["label"].string ?? "",
                body: body,
                group: group,
                provenance: provenance
            ))
        }

        skillUseCounts = usage
        memoryEntries = entries
        memoryLoaded = true
    }

    /// DELETE /api/learning/node — "Forget". Returns an error string, or nil.
    /// NOTE: the backend has no way to re-create a deleted memory chunk, so
    /// there is no undo (reported in UNIMPLEMENTED).
    func forgetMemory(id: String) async -> String? {
        guard let rest = store.rest else { return "Backend not connected" }
        do {
            try await rest.deleteLearningNode(id: id)
            memoryEntries.removeAll { $0.id == id }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// `commands.catalog` RPC → CUSTOM ("User commands" bucket, quick_commands
    /// from config.yaml) and BUILT-IN (every other registry category).
    func refreshCommands() async {
        guard store.connectionState.isReady else { return }
        do {
            let result = try await store.rpc.request("commands.catalog", params: .object([:]), timeout: 30)
            var custom: [SkillsCommandEntry] = []
            var builtin: [SkillsCommandEntry] = []
            let categories = result["categories"].arrayValue ?? []
            for category in categories {
                let catName = category["name"].string ?? ""
                for pair in category["pairs"].arrayValue ?? [] {
                    guard let name = pair[0].string, !name.isEmpty else { continue }
                    let entry = SkillsCommandEntry(name: name, detail: pair[1].string ?? "")
                    if catName == "User commands" {
                        custom.append(entry)
                    } else {
                        builtin.append(entry)
                    }
                }
            }
            if categories.isEmpty {
                // Older gateway: flat pairs only.
                for pair in result["pairs"].arrayValue ?? [] {
                    guard let name = pair[0].string, !name.isEmpty else { continue }
                    builtin.append(SkillsCommandEntry(name: name, detail: pair[1].string ?? ""))
                }
            }
            customCommands = custom
            builtinCommands = builtin
            commandsLoaded = true
        } catch {
            commandsLoaded = true
        }
    }

    /// `GET /api/messaging/platforms` fetched raw (the typed RestClient model
    /// drops `docs_url`, which the Connect button needs).
    func refreshMessaging() async {
        guard let rest = store.rest else { return }
        do {
            var components = URLComponents(url: rest.baseURL, resolvingAgainstBaseURL: false)
            components?.path = "/api/messaging/platforms"
            guard let url = components?.url else { throw RestError.unexpectedShape("bad messaging URL") }
            var request = URLRequest(url: url)
            request.setValue(rest.token, forHTTPHeaderField: "X-Hermes-Session-Token")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw RestError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
            }
            guard let json = JSONValue.decode(data) else { throw RestError.invalidJSON }

            var cards: [SkillsMessagingCard] = []
            for entry in json["platforms"].arrayValue ?? [] {
                guard let platform = MessagingPlatform(json: entry) else { continue }
                let gatewayState = store.backendStatus?.gatewayPlatforms[platform.id]?.state
                let connected = platform.state == "connected" || gatewayState == "connected"
                let detail: String
                if let error = platform.errorMessage, !error.isEmpty {
                    detail = error
                } else if !platform.description.isEmpty {
                    detail = platform.description
                } else {
                    detail = platform.state.replacingOccurrences(of: "_", with: " ")
                }
                cards.append(SkillsMessagingCard(
                    id: platform.id,
                    name: platform.name,
                    detail: detail,
                    glyph: Self.glyph(forPlatform: platform.id, name: platform.name),
                    connected: connected,
                    docsURL: entry["docs_url"].string.flatMap(URL.init(string:)),
                    alwaysOn: false
                ))
            }
            // This app IS a live gateway client — the CLI / TUI channel is
            // always on whenever we're connected at all.
            cards.append(SkillsMessagingCard(
                id: "cli", name: "CLI / TUI", detail: "Always on", glyph: ">",
                connected: true, docsURL: nil, alwaysOn: true
            ))
            messagingCards = cards
            messagingLoaded = true
        } catch {
            messagingLoaded = true
        }
    }

    private static func glyph(forPlatform id: String, name: String) -> String {
        switch id {
        case "signal": return "§"
        case "email": return "@"
        case "cli", "local": return ">"
        default: return String(name.prefix(1)).uppercased()
        }
    }

    /// `GET /api/tools/toolsets` + `GET /api/mcp/servers`.
    func refreshTools() async {
        guard let rest = store.rest else { return }
        do {
            let sets = try await rest.toolsets()
            let raw = try await rest.mcpServers()
            let servers: [SkillsMcpServer] = (raw["servers"].arrayValue ?? []).compactMap { entry in
                guard let name = entry["name"].string else { return nil }
                return SkillsMcpServer(
                    name: name,
                    enabled: entry["enabled"].bool ?? true,
                    transport: entry["transport"].string ?? "",
                    toolCount: entry["tools"].arrayValue?.count
                )
            }
            toolsets = sets
            mcpServers = servers
            toolsLoaded = true
        } catch {
            toolsLoaded = true
        }
    }

    // MARK: - Mutations (return error string or nil)

    /// PUT /api/tools/toolsets/{name} {enabled}
    func setToolsetEnabled(_ name: String, _ enabled: Bool) async -> String? {
        guard let rest = store.rest else { return "Backend not connected" }
        do {
            try await rest.toggleToolset(name: name, enabled: enabled)
            await refreshTools()
            return nil
        } catch {
            await refreshTools()
            return error.localizedDescription
        }
    }

    /// PUT /api/mcp/servers/{name}/enabled {enabled}
    func setMcpServerEnabled(_ name: String, _ enabled: Bool) async -> String? {
        guard let rest = store.rest else { return "Backend not connected" }
        do {
            try await rest.setMcpServerEnabled(name: name, enabled: enabled)
            await refreshTools()
            return nil
        } catch {
            await refreshTools()
            return error.localizedDescription
        }
    }

    /// PUT /api/skills/toggle {name, enabled}
    func setSkillEnabled(_ name: String, _ enabled: Bool) async -> String? {
        guard let rest = store.rest else { return "Backend not connected" }
        do {
            try await rest.toggleSkill(name: name, enabled: enabled)
            await store.refreshSkills()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}
