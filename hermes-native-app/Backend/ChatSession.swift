//
//  ChatSession.swift
//  hermes-native-app
//
//  One open conversation: owns the live<->stored session-id mapping, assembles
//  the transcript from replayed messages + live gateway events, and publishes
//  changes via Combine for the AppKit chat view to bind against.
//

import Foundation
import Combine

public enum ChatSessionError: Error, LocalizedError {
    /// prompt.submit hit 4009 — offer interrupt / steer / queue in the UI.
    case busy
    case notOpen
    /// Backend info.desktop_contract < 2 — too old for this client.
    case incompatibleBackend(contract: Int)
    case backend(String)

    public var errorDescription: String? {
        switch self {
        case .busy: return "Hermes is still working on the current turn."
        case .notOpen: return "This conversation is not connected."
        case .incompatibleBackend(let contract):
            return "The installed Hermes backend is too old for this app (desktop contract \(contract) < 2). Run 'hermes update'."
        case .backend(let message): return message
        }
    }
}

/// A single row of the rendered conversation.
public struct TranscriptItem: Identifiable, Sendable {
    public enum Kind: Sendable {
        case user(UserMessage)
        case assistant(AssistantMessage)
        case tool(ToolCard)
        case system(String)
        case divider(String)
    }

    public let id: UUID
    public var kind: Kind

    public init(kind: Kind) {
        id = UUID()
        self.kind = kind
    }
}

public struct UserMessage: Sendable {
    public var text: String
    public var timestamp: Date?
    public var source: String?
}

public struct AssistantMessage: Sendable {
    public var text: String
    public var reasoning: String
    public var isStreaming: Bool
    /// "complete" | "interrupted" | "error" once finished.
    public var status: String?
    public var usage: UsageStats?
}

/// Tool execution card keyed by tool_id; transitions running -> complete.
public struct ToolCard: Sendable {
    public enum Status: Sendable, Equatable { case running, generating, complete, failed }

    public let toolID: String
    public var name: String
    public var context: String?
    public var argsText: String?
    public var args: JSONValue
    public var result: JSONValue
    public var resultText: String?
    public var summary: String?
    public var inlineDiff: String?
    public var progressPreview: String?
    public var durationSeconds: Double?
    public var status: Status
}

/// One row of the SUBAGENTS card.
public struct SubagentRow: Identifiable, Sendable {
    public let id: String
    public var goal: String
    public var status: String
    public var detail: String?
    public var taskIndex: Int
    public var taskCount: Int?
    public var isFinished: Bool
}

@MainActor
public final class ChatSession: ObservableObject, Identifiable {

    public nonisolated let id = UUID()

    /// Per-connection live id — changes on every resume; nil until opened.
    public private(set) var liveSessionID: String?
    /// Durable id used by REST + session.resume.
    public private(set) var storedSessionID: String?

    @Published public private(set) var transcript: [TranscriptItem] = []
    @Published public private(set) var subagents: [SubagentRow] = []
    @Published public private(set) var info: SessionRuntimeInfo?
    @Published public private(set) var usage: UsageStats?
    @Published public private(set) var title: String?
    @Published public private(set) var isRunning = false
    @Published public private(set) var isThinking = false
    @Published public private(set) var statusText: String?
    @Published public private(set) var todos: [JSONValue] = []
    @Published public private(set) var lastError: String?

    private let client: JSONRPCClient
    private var toolItemIndex: [String: Int] = [:]
    private var streamingAssistantIndex: Int?
    private var isClosed = false
    #if DEBUG
    /// Frontend mock session — `submit` echoes a canned reply, no RPC.
    private(set) var isMock = false
    #endif

    public init(client: JSONRPCClient) {
        self.client = client
    }

    // MARK: Lifecycle

    /// session.create — new conversation. Gates on desktop_contract >= 2.
    public func create(
        cwd: String? = nil,
        model: String? = nil,
        provider: String? = nil,
        reasoningEffort: String? = nil,
        fast: Bool = false
    ) async throws {
        var params: [String: JSONValue] = [
            "cols": 96,
            "source": "desktop",
        ]
        if let cwd { params["cwd"] = .string(cwd) }
        if let model { params["model"] = .string(model) }
        if let provider { params["provider"] = .string(provider) }
        if let reasoningEffort { params["reasoning_effort"] = .string(reasoningEffort) }
        if fast { params["fast"] = .bool(true) }

        let result = try await client.request("session.create", params: .object(params))
        try adopt(openResult: result, resumedStoredID: nil)
    }

    /// session.resume — reopen a stored conversation; live id is fresh and the
    /// full transcript is replayed.
    public func resume(storedID: String) async throws {
        let result = try await client.request("session.resume", params: .object([
            "session_id": .string(storedID),
            "cols": 96,
            "source": "desktop",
        ]))
        try adopt(openResult: result, resumedStoredID: storedID)
    }

    private func adopt(openResult json: JSONValue, resumedStoredID: String?) throws {
        guard let open = SessionOpenResult(json: json) else {
            throw ChatSessionError.backend("session open returned no session_id")
        }
        if let info = open.info, info.desktopContract > 0, info.desktopContract < 2 {
            throw ChatSessionError.incompatibleBackend(contract: info.desktopContract)
        }
        liveSessionID = open.liveSessionID
        // "resumed" points at the resolved chain tip; fall back to the id we asked for.
        storedSessionID = open.storedSessionID ?? resumedStoredID ?? storedSessionID
        info = open.info
        usage = open.info?.usage
        title = open.info?.title.flatMap { $0.isEmpty ? nil : $0 }
        isRunning = open.running
        rebuildTranscript(from: open.messages)
        if let user = open.inflightUser, !user.isEmpty {
            transcript.append(TranscriptItem(kind: .user(UserMessage(text: user, timestamp: nil, source: nil))))
        }
        if let assistant = open.inflightAssistant, !assistant.isEmpty {
            appendStreamingAssistant(initialText: assistant)
        }
    }

    /// session.close — call when the conversation UI goes away.
    public func close() async {
        guard let liveSessionID, !isClosed else { return }
        isClosed = true
        _ = try? await client.request("session.close", params: .object([
            "session_id": .string(liveSessionID),
        ]), timeout: 15)
    }

    // MARK: Turn control

    /// prompt.submit — fire-and-forget (ack may take minutes; completion comes
    /// via message.complete). Recovers once from a lost live session by
    /// re-resuming the stored id. 4009 surfaces as ChatSessionError.busy.
    public func submit(text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        #if DEBUG
        if isMock { await mockSubmit(text: trimmed); return }
        #endif
        guard liveSessionID != nil else { throw ChatSessionError.notOpen }

        transcript.append(TranscriptItem(kind: .user(UserMessage(text: trimmed, timestamp: Date(), source: nil))))
        isRunning = true
        lastError = nil

        do {
            try await sendSubmit(text: trimmed)
        } catch let error as RPCError {
            switch error.serverCode {
            case 4009:
                throw ChatSessionError.busy
            case 4001, 4007:
                // Live id died (WS drop reaped it) — resume the stored id, retry once.
                guard let storedSessionID else {
                    isRunning = false
                    throw ChatSessionError.backend(error.localizedDescription)
                }
                let userItems = transcript // preserve optimistic row across the rebuild
                try await resume(storedID: storedSessionID)
                if transcript.count < userItems.count { transcript = userItems }
                isRunning = true
                do {
                    try await sendSubmit(text: trimmed)
                } catch let retryError as RPCError where retryError.serverCode == 4009 {
                    throw ChatSessionError.busy
                } catch {
                    // Any other retry failure (transport, timeout, reaped again):
                    // clear the optimistic running state so the UI isn't stuck.
                    isRunning = false
                    lastError = error.localizedDescription
                    throw ChatSessionError.backend(error.localizedDescription)
                }
            default:
                isRunning = false
                lastError = error.localizedDescription
                throw ChatSessionError.backend(error.localizedDescription)
            }
        }
    }

    private func sendSubmit(text: String) async throws {
        guard let liveSessionID else { throw ChatSessionError.notOpen }
        _ = try await client.request("prompt.submit", params: .object([
            "session_id": .string(liveSessionID),
            "text": .string(text),
        ]), timeout: JSONRPCClient.promptSubmitTimeout)
    }

    /// session.interrupt — cancel the running turn (Esc / Stop).
    public func interrupt() async {
        guard let liveSessionID else { return }
        _ = try? await client.request("session.interrupt", params: .object([
            "session_id": .string(liveSessionID),
        ]), timeout: 30)
    }

    /// session.steer — inject text mid-turn without interrupting.
    /// Returns true when the backend queued it.
    @discardableResult
    public func steer(text: String) async throws -> Bool {
        guard let liveSessionID else { throw ChatSessionError.notOpen }
        let result = try await client.request("session.steer", params: .object([
            "session_id": .string(liveSessionID),
            "text": .string(text),
        ]), timeout: 30)
        let queued = result["status"].string == "queued"
        if queued {
            transcript.append(TranscriptItem(kind: .system("Steered: \(text)")))
        }
        return queued
    }

    // MARK: Event intake

    /// Feed a gateway event that belongs to this session (HermesStore routes by
    /// live session id; nil-session events belong to the focused turn).
    public func handle(event: GatewayEvent) {
        switch event.payload {
        case .messageStart:
            isThinking = false
            statusText = nil
            appendStreamingAssistant(initialText: "")
            isRunning = true

        case .messageDelta(let text):
            appendAssistantText(text)

        case .messageComplete(let text, let reasoning, let usage, let status):
            finishAssistant(fullText: text, reasoning: reasoning, usage: usage, status: status)

        case .thinkingDelta:
            isThinking = true

        case .reasoningDelta(let text):
            appendAssistantReasoning(text)

        case .reasoningAvailable(let text):
            replaceAssistantReasoning(text)

        case .statusUpdate(let kind, let text):
            statusText = text ?? kind

        case .toolStart(let payload):
            isThinking = false
            let card = ToolCard(
                toolID: payload.toolID,
                name: payload.name,
                context: payload.context,
                argsText: payload.argsText,
                args: .null,
                result: .null,
                resultText: nil,
                summary: nil,
                inlineDiff: nil,
                progressPreview: nil,
                durationSeconds: nil,
                status: .running
            )
            toolItemIndex[payload.toolID] = transcript.count
            transcript.append(TranscriptItem(kind: .tool(card)))

        case .toolProgress(let name, let preview):
            updateLatestTool(named: name) { $0.progressPreview = preview ?? $0.progressPreview }

        case .toolGenerating(let name):
            updateLatestTool(named: name) { $0.status = .generating }

        case .toolComplete(let payload):
            completeTool(payload)

        case .sessionInfo(let runtimeInfo):
            info = runtimeInfo
            if let infoUsage = runtimeInfo.usage { usage = infoUsage }
            isRunning = runtimeInfo.running
            if let newTitle = runtimeInfo.title, !newTitle.isEmpty { title = newTitle }

        case .sessionTitle(let storedID, let newTitle, let pending):
            if !pending, storedID == nil || storedID == storedSessionID, !newTitle.isEmpty {
                title = newTitle
            }

        case .subagent(let phase, let payload):
            applySubagent(phase: phase, info: payload)

        case .error(let message):
            lastError = message
            transcript.append(TranscriptItem(kind: .system("Error: \(message)")))
            isRunning = false
            isThinking = false

        case .approvalRequest, .clarifyRequest, .sudoRequest, .secretRequest,
             .terminalReadRequest, .gatewayReady, .unknown:
            break // owned by HermesStore's attention queue / connection logic
        }
    }

    // MARK: Transcript assembly

    private func rebuildTranscript(from messages: [ReplayMessage]) {
        toolItemIndex.removeAll()
        streamingAssistantIndex = nil
        subagents = []
        var items: [TranscriptItem] = []
        for message in messages {
            switch message.role {
            case "user":
                items.append(TranscriptItem(kind: .user(UserMessage(text: message.text, timestamp: nil, source: nil))))
            case "assistant":
                items.append(TranscriptItem(kind: .assistant(AssistantMessage(
                    text: message.text,
                    reasoning: message.reasoning ?? "",
                    isStreaming: false,
                    status: "complete",
                    usage: nil
                ))))
            case "tool":
                let name = message.name ?? "tool"
                items.append(TranscriptItem(kind: .tool(ToolCard(
                    toolID: UUID().uuidString,
                    name: name,
                    context: message.context,
                    argsText: nil,
                    args: .null,
                    result: .null,
                    resultText: nil,
                    summary: nil,
                    inlineDiff: nil,
                    progressPreview: nil,
                    durationSeconds: nil,
                    status: .complete
                ))))
            case "system":
                items.append(TranscriptItem(kind: .system(message.text)))
            default:
                break
            }
        }
        transcript = items
    }

    private func appendStreamingAssistant(initialText: String) {
        let item = TranscriptItem(kind: .assistant(AssistantMessage(
            text: initialText, reasoning: "", isStreaming: true, status: nil, usage: nil
        )))
        streamingAssistantIndex = transcript.count
        transcript.append(item)
    }

    private func withStreamingAssistant(_ mutate: (inout AssistantMessage) -> Void) {
        if streamingAssistantIndex == nil { appendStreamingAssistant(initialText: "") }
        guard let index = streamingAssistantIndex, transcript.indices.contains(index),
              case .assistant(var message) = transcript[index].kind else { return }
        mutate(&message)
        transcript[index].kind = .assistant(message)
    }

    private func appendAssistantText(_ text: String) {
        guard !text.isEmpty else { return }
        withStreamingAssistant { $0.text += text }
    }

    private func appendAssistantReasoning(_ text: String) {
        guard !text.isEmpty else { return }
        withStreamingAssistant { $0.reasoning += text }
    }

    private func replaceAssistantReasoning(_ text: String) {
        withStreamingAssistant { $0.reasoning = text }
    }

    private func finishAssistant(fullText: String, reasoning: String?, usage: UsageStats?, status: String) {
        withStreamingAssistant { message in
            if !fullText.isEmpty { message.text = fullText } // authoritative full text
            if let reasoning, !reasoning.isEmpty { message.reasoning = reasoning }
            message.isStreaming = false
            message.status = status
            message.usage = usage
        }
        streamingAssistantIndex = nil
        if let usage { self.usage = usage }
        isRunning = false
        isThinking = false
        statusText = nil
        // Parallel subagent rows are per-turn UI; keep finished rows visible
        // until the next turn starts a fresh batch.
        if status == "complete" {
            for index in subagents.indices { subagents[index].isFinished = true }
        }
    }

    private func completeTool(_ payload: ToolCompletePayload) {
        if let updated = payload.todos { todos = updated }
        let apply: (inout ToolCard) -> Void = { card in
            card.name = payload.name
            card.args = payload.args
            card.result = payload.result
            card.resultText = payload.resultText
            card.summary = payload.summary
            card.inlineDiff = payload.inlineDiff
            card.durationSeconds = payload.durationSeconds
            card.status = payload.error == nil ? .complete : .failed
        }
        if let index = toolItemIndex[payload.toolID], transcript.indices.contains(index),
           case .tool(var card) = transcript[index].kind {
            apply(&card)
            transcript[index].kind = .tool(card)
            return
        }
        // tool.complete without a matching tool.start (verbose-off inline diffs).
        var card = ToolCard(
            toolID: payload.toolID, name: payload.name, context: nil, argsText: nil,
            args: .null, result: .null, resultText: nil, summary: nil, inlineDiff: nil,
            progressPreview: nil, durationSeconds: nil, status: .complete
        )
        apply(&card)
        toolItemIndex[payload.toolID] = transcript.count
        transcript.append(TranscriptItem(kind: .tool(card)))
    }

    private func updateLatestTool(named name: String?, _ mutate: (inout ToolCard) -> Void) {
        for index in transcript.indices.reversed() {
            guard case .tool(var card) = transcript[index].kind else { continue }
            if card.status == .complete || card.status == .failed { continue }
            // With parallel tools, progress/generating events carry only a name —
            // skip any running card whose name doesn't match so the update lands
            // on the right card, not merely the most recent running one.
            if let name, !name.isEmpty, card.name != name { continue }
            mutate(&card)
            transcript[index].kind = .tool(card)
            return
        }
    }

    private func applySubagent(phase: SubagentPhase, info payload: SubagentEventInfo) {
        let rowID = payload.subagentID ?? "task-\(payload.taskIndex)"
        let detail = payload.toolPreview ?? payload.text ?? payload.summary ?? payload.toolName
        let status: String
        switch phase {
        case .spawnRequested: status = "queued"
        case .start: status = "running"
        case .thinking: status = "thinking"
        case .tool: status = payload.toolName.map { "tool: \($0)" } ?? "tool"
        case .progress: status = payload.status ?? "running"
        case .complete: status = payload.status ?? "done"
        }
        if let index = subagents.firstIndex(where: { $0.id == rowID }) {
            subagents[index].status = status
            if let detail, !detail.isEmpty { subagents[index].detail = detail }
            if !payload.goal.isEmpty { subagents[index].goal = payload.goal }
            subagents[index].isFinished = (phase == .complete)
        } else {
            subagents.append(SubagentRow(
                id: rowID,
                goal: payload.goal,
                status: status,
                detail: detail,
                taskIndex: payload.taskIndex,
                taskCount: payload.taskCount,
                isFinished: phase == .complete
            ))
        }
    }
}

#if DEBUG
extension ChatSession {
    /// Seed a mock conversation for frontend work (no backend). Same-file access
    /// lets this write the `private(set)` published state.
    func seedMock(transcript: [TranscriptItem], title: String?, info: SessionRuntimeInfo?, usage: UsageStats?) {
        self.transcript = transcript
        self.title = title
        self.info = info
        self.usage = usage
        liveSessionID = "mock-\(id.uuidString.prefix(8))"
        storedSessionID = liveSessionID
        isMock = true
    }

    /// Echo the user's message and a canned assistant reply, with a brief
    /// "thinking" beat so the composer/running states exercise the UI.
    fileprivate func mockSubmit(text: String) async {
        transcript.append(TranscriptItem(kind: .user(UserMessage(text: text, timestamp: Date(), source: "desktop"))))
        isRunning = true
        isThinking = true
        statusText = "Thinking…"
        try? await Task.sleep(for: .milliseconds(650))
        isThinking = false
        statusText = nil
        let reply = AssistantMessage(
            text: "You're in frontend mock mode, so this reply is canned — the Hermes backend isn't running. Your message was received:\n\n“\(text)”",
            reasoning: "",
            isStreaming: false,
            status: "complete",
            usage: nil
        )
        transcript.append(TranscriptItem(kind: .assistant(reply)))
        isRunning = false
    }
}
#endif
