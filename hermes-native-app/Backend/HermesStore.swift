//
//  HermesStore.swift
//  hermes-native-app
//
//  App-wide facade the AppKit UI binds to: drives supervisor -> handshake ->
//  WebSocket connect, owns the session list, the focused ChatSession, and the
//  cross-session attention queue (approval/clarify/sudo/secret/terminal-read).
//

import Foundation
import Combine

/// One blocking interaction awaiting a user answer. ALWAYS answer (or dismiss
/// knowingly) — the server side of the turn stalls until then.
public struct AttentionItem: Identifiable, Sendable {
    public enum Kind: Sendable {
        case approval(ApprovalRequestPayload)
        case clarify(ClarifyRequestPayload)
        case sudo(SudoRequestPayload)
        case secret(SecretRequestPayload)
        case terminalRead(TerminalReadRequestPayload)
    }

    public let id: UUID
    /// Live session id the event arrived on (nil = focused turn).
    public let sessionID: String?
    public let receivedAt: Date
    public let kind: Kind

    init(sessionID: String?, kind: Kind) {
        id = UUID()
        self.sessionID = sessionID
        receivedAt = Date()
        self.kind = kind
    }
}

/// approval.respond choices (server: once | session | always | deny).
public enum ApprovalChoice: String, Sendable {
    case once, session, always, deny
}

@MainActor
public final class HermesStore: ObservableObject {

    public enum ConnectionState: Equatable {
        case idle
        case launching
        case connecting
        case ready(BackendConnection)
        case failed(String)

        public var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    // MARK: Published state

    @Published public private(set) var connectionState: ConnectionState = .idle
    @Published public private(set) var sessions: [SessionSummary] = []
    @Published public private(set) var sessionsTotal = 0
    @Published public private(set) var focusedSession: ChatSession?
    @Published public private(set) var attentionItems: [AttentionItem] = []
    @Published public private(set) var modelInfo: ModelInfo?
    @Published public private(set) var modelOptions: ModelOptions?
    @Published public private(set) var cronJobs: [CronJob] = []
    @Published public private(set) var skills: [Skill] = []
    @Published public private(set) var usageAnalytics: AnalyticsUsage?
    @Published public private(set) var backendStatus: StatusResponse?
    /// Most recent non-fatal operation error, for toast/banner surfaces.
    @Published public private(set) var lastActionError: String?

    // MARK: Members

    public let rpc = JSONRPCClient()
    public private(set) var rest: RestClient?
    private let supervisor = BackendSupervisor()
    private var eventCancellable: AnyCancellable?
    private var started = false
    #if DEBUG
    /// Frontend mock mode: the store runs entirely on MockData and never spawns
    /// or dials the backend. Set by `startMock()`.
    private var mockMode = false
    #endif

    public init() {}

    // MARK: Connection state machine

    /// idle -> launching (spawn+handshake) -> connecting (WS) -> ready.
    public func start() async {
        guard !started else { return }
        started = true
        connectionState = .launching

        await supervisor.setExitHandler { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                if case .failed = self.connectionState { return }
                self.connectionState = .failed("Hermes backend exited (status \(status)). See ~/Library/Logs/HermesDesktop/backend.log.")
            }
        }

        do {
            let connection = try await supervisor.start()
            rest = RestClient(connection: connection)
            connectionState = .connecting

            subscribeToEvents()
            await rpc.setReconnectHandler { [weak self] in
                await self?.handleReconnected()
            }
            try await rpc.connect(url: connection.wsURL)
            // First server frame is the gateway.ready event; a successful WS
            // open is the operative signal, so flip to ready now.
            connectionState = .ready(connection)
            await initialRefresh()
        } catch {
            started = false
            connectionState = .failed(error.localizedDescription)
        }
    }

    /// Terminate everything. Call from applicationWillTerminate.
    /// No graceful session.close here: we own the backend and stop it next —
    /// sessions persist in its SQLite store and resume by stored id. A close
    /// RPC over a torn socket would only delay Quit.
    public func shutdown() async {
        focusedSession = nil
        await rpc.disconnect()
        await supervisor.stop()
        started = false
        connectionState = .idle
    }

    /// Retry after .failed.
    public func restart() async {
        await shutdown()
        await start()
    }

    private func initialRefresh() async {
        async let a: Void = refreshSessions()
        async let b: Void = refreshModel()
        async let c: Void = refreshCronJobs()
        async let d: Void = refreshSkills()
        async let e: Void = refreshAnalytics()
        async let f: Void = refreshStatus()
        _ = await (a, b, c, d, e, f)
    }

    /// After sleep/wake the WS reconnects with fresh backoff; parked sessions
    /// are reaped ~20 s after the drop, so re-resume the focused one promptly.
    private func handleReconnected() async {
        if let focusedSession, let storedID = focusedSession.storedSessionID {
            do {
                try await focusedSession.resume(storedID: storedID)
            } catch {
                lastActionError = "Could not re-open conversation: \(error.localizedDescription)"
            }
        }
        await refreshStatus()
        await refreshSessions()
    }

    // MARK: Event routing

    private func subscribeToEvents() {
        eventCancellable = rpc.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.route(event)
            }
    }

    private func route(_ event: GatewayEvent) {
        // Blocking interactions aggregate across every session.
        switch event.payload {
        case .approvalRequest(let payload):
            attentionItems.append(AttentionItem(sessionID: event.sessionID, kind: .approval(payload)))
        case .clarifyRequest(let payload):
            attentionItems.append(AttentionItem(sessionID: event.sessionID, kind: .clarify(payload)))
        case .sudoRequest(let payload):
            attentionItems.append(AttentionItem(sessionID: event.sessionID, kind: .sudo(payload)))
        case .secretRequest(let payload):
            attentionItems.append(AttentionItem(sessionID: event.sessionID, kind: .secret(payload)))
        case .terminalReadRequest(let payload):
            attentionItems.append(AttentionItem(sessionID: event.sessionID, kind: .terminalRead(payload)))
        default:
            break
        }

        if case .sessionTitle = event.payload {
            focusedSession?.handle(event: event)
            Task { await self.refreshSessions() }
            return
        }

        guard let focusedSession else { return }
        if let sid = event.sessionID {
            if sid == focusedSession.liveSessionID {
                focusedSession.handle(event: event)
            }
        } else {
            // Events missing session_id belong to the focused turn, EXCEPT
            // subagent.* which must be dropped (protocol contract).
            if event.type.hasPrefix("subagent.") { return }
            focusedSession.handle(event: event)
        }
    }

    // MARK: Session selection

    /// Resume a stored conversation as the focused chat (closing the previous live one).
    public func selectSession(storedID: String) async {
        #if DEBUG
        if mockMode { focusedSession = makeMockSession(storedID: storedID); return }
        #endif
        let previous = focusedSession
        let chat = ChatSession(client: rpc)
        do {
            try await chat.resume(storedID: storedID)
            focusedSession = chat
            if let previous { await previous.close() }
        } catch {
            lastActionError = "Could not open conversation: \(error.localizedDescription)"
        }
    }

    /// Start a brand-new conversation as the focused chat.
    public func newSession(
        cwd: String? = nil,
        model: String? = nil,
        provider: String? = nil,
        reasoningEffort: String? = nil
    ) async {
        #if DEBUG
        if mockMode { focusedSession = makeMockSession(storedID: nil); return }
        #endif
        let previous = focusedSession
        let chat = ChatSession(client: rpc)
        do {
            try await chat.create(cwd: cwd, model: model, provider: provider, reasoningEffort: reasoningEffort)
            focusedSession = chat
            if let previous { await previous.close() }
        } catch {
            lastActionError = "Could not start a conversation: \(error.localizedDescription)"
        }
    }

    // MARK: Attention responses

    /// approval.respond {session_id, choice} — choice keyed to the session.
    public func answerApproval(_ item: AttentionItem, choice: ApprovalChoice) async {
        guard case .approval = item.kind else { return }
        let sid = item.sessionID ?? focusedSession?.liveSessionID ?? ""
        await respond(item: item, method: "approval.respond", params: [
            "session_id": .string(sid),
            "choice": .string(choice.rawValue),
        ])
    }

    /// clarify.respond {request_id, answer}
    public func answerClarify(_ item: AttentionItem, answer: String) async {
        guard case .clarify(let payload) = item.kind else { return }
        await respond(item: item, method: "clarify.respond", params: [
            "request_id": .string(payload.requestID),
            "answer": .string(answer),
        ])
    }

    /// sudo.respond {request_id, password} — 120 s server window.
    public func answerSudo(_ item: AttentionItem, password: String) async {
        guard case .sudo(let payload) = item.kind else { return }
        await respond(item: item, method: "sudo.respond", params: [
            "request_id": .string(payload.requestID),
            "password": .string(password),
        ])
    }

    /// secret.respond {request_id, value}
    public func answerSecret(_ item: AttentionItem, value: String) async {
        guard case .secret(let payload) = item.kind else { return }
        await respond(item: item, method: "secret.respond", params: [
            "request_id": .string(payload.requestID),
            "value": .string(value),
        ])
    }

    /// terminal.read.respond {request_id, text} — 30 s server window.
    public func answerTerminalRead(_ item: AttentionItem, text: String) async {
        guard case .terminalRead(let payload) = item.kind else { return }
        await respond(item: item, method: "terminal.read.respond", params: [
            "request_id": .string(payload.requestID),
            "text": .string(text),
        ])
    }

    /// Drop an item without answering (the server times out on its own —
    /// approvals get BLOCKED after ~300 s).
    public func dismissAttention(_ item: AttentionItem) {
        attentionItems.removeAll { $0.id == item.id }
    }

    private func respond(item: AttentionItem, method: String, params: [String: JSONValue]) async {
        do {
            _ = try await rpc.request(method, params: .object(params), timeout: 30)
        } catch {
            lastActionError = "Could not send response: \(error.localizedDescription)"
        }
        attentionItems.removeAll { $0.id == item.id }
    }

    // MARK: Domain refresh

    public func refreshSessions(limit: Int = 60, archived: String = "exclude") async {
        guard let rest else { return }
        do {
            let page = try await rest.sessions(limit: limit, archived: archived, order: "recent")
            sessions = page.sessions
            sessionsTotal = page.total
        } catch {
            reportRefreshFailure("sessions", error)
        }
    }

    public func refreshModel() async {
        guard let rest else { return }
        do {
            modelInfo = try await rest.modelInfo()
            modelOptions = try await rest.modelOptions()
        } catch {
            reportRefreshFailure("model", error)
        }
    }

    public func refreshCronJobs() async {
        guard let rest else { return }
        do {
            cronJobs = try await rest.cronJobs()
        } catch {
            reportRefreshFailure("automations", error)
        }
    }

    public func refreshSkills() async {
        guard let rest else { return }
        do {
            skills = try await rest.skills()
        } catch {
            reportRefreshFailure("skills", error)
        }
    }

    public func refreshAnalytics(days: Int = 30) async {
        guard let rest else { return }
        do {
            usageAnalytics = try await rest.analyticsUsage(days: days)
        } catch {
            reportRefreshFailure("usage analytics", error)
        }
    }

    public func refreshStatus() async {
        guard let rest else { return }
        do {
            backendStatus = try await rest.status()
        } catch {
            reportRefreshFailure("status", error)
        }
    }

    private func reportRefreshFailure(_ domain: String, _ error: Error) {
        lastActionError = "Could not load \(domain): \(error.localizedDescription)"
    }

    // MARK: Session list mutations (sidebar context menu)

    public func renameSession(id: String, title: String) async {
        guard let rest else { return }
        do {
            try await rest.updateSession(id: id, title: title)
            await refreshSessions()
        } catch {
            lastActionError = "Rename failed: \(error.localizedDescription)"
        }
    }

    public func setSessionArchived(id: String, archived: Bool) async {
        guard let rest else { return }
        do {
            try await rest.updateSession(id: id, archived: archived)
            await refreshSessions()
        } catch {
            lastActionError = "Archive failed: \(error.localizedDescription)"
        }
    }

    public func deleteSession(id: String) async {
        guard let rest else { return }
        do {
            try await rest.deleteSession(id: id)
            if focusedSession?.storedSessionID == id {
                await focusedSession?.close()
                focusedSession = nil
            }
            await refreshSessions()
        } catch {
            lastActionError = "Delete failed: \(error.localizedDescription)"
        }
    }

    public func clearActionError() {
        lastActionError = nil
    }
}

#if DEBUG
extension HermesStore {
    /// Seed every published domain with MockData (Xcode previews). Same-file
    /// access lets this write the `private(set)` published properties; bound
    /// views repaint via their Combine subscriptions.
    func seedPreviewData() { applyMockData() }

    /// Full frontend mock mode: populate the UI with MockData and report ready,
    /// with NO backend spawn or socket. DEBUG builds default to this (AppDelegate);
    /// set HERMES_REAL=1 to use the real backend instead.
    func startMock() {
        guard !started else { return }
        started = true
        mockMode = true
        applyMockData()
    }

    private func applyMockData() {
        sessions = MockData.sessions()
        sessionsTotal = sessions.count
        skills = MockData.skills()
        cronJobs = MockData.cronJobs()
        usageAnalytics = MockData.usage()
        modelInfo = MockData.modelInfo()
        backendStatus = MockData.status()
        connectionState = .ready(MockData.connection)
        focusedSession = makeMockSession(storedID: sessions.first?.id)
    }

    /// A mock ChatSession — full transcript for a resumed conversation, empty for
    /// a brand-new one (nil id) so the composer/empty state shows.
    func makeMockSession(storedID: String?) -> ChatSession {
        let chat = ChatSession(client: rpc)
        let title = sessions.first { $0.id == storedID }?.title ?? "New conversation"
        chat.seedMock(
            transcript: storedID == nil ? [] : MockData.transcript(),
            title: storedID == nil ? nil : title,
            info: MockData.runtimeInfo(),
            usage: MockData.usageStats()
        )
        return chat
    }
}
#endif
