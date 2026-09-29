//
//  JSONRPCClient.swift
//  hermes-native-app
//
//  URLSessionWebSocketTask JSON-RPC 2.0 transport for ws://…/api/ws?token=…
//  One JSON object per text frame. Responses arrive out of order — matched
//  strictly by integer id. Notifications (method == "event") fan out to a
//  Combine publisher and AsyncStreams. Auto-reconnect with 1,2,4…15 s backoff.
//

import Foundation
import Combine

public enum RPCError: Error, LocalizedError, Sendable {
    case notConnected
    case timeout(method: String)
    /// JSON-RPC error object from the server (4009 busy, 4090 limit, 5032 init timeout, …).
    case server(code: Int, message: String)
    case transport(String)
    case connectFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Hermes gateway is not connected"
        case .timeout(let method): return "Request timed out: \(method)"
        case .server(let code, let message): return "\(message) (code \(code))"
        case .transport(let detail): return "Gateway transport error: \(detail)"
        case .connectFailed(let detail): return "Could not connect to Hermes gateway: \(detail)"
        }
    }

    public var serverCode: Int? {
        if case .server(let code, _) = self { return code }
        return nil
    }
}

public actor JSONRPCClient {

    public enum ConnectionState: Equatable, Sendable {
        case idle
        case connecting
        case open
        case reconnecting(attempt: Int)
        case closed
        case failed(String)
    }

    public static let defaultRequestTimeout: TimeInterval = 120
    /// prompt.submit ack can legitimately take minutes; matches agent.gateway_timeout.
    public static let promptSubmitTimeout: TimeInterval = 1800
    private static let connectTimeout: TimeInterval = 15
    private static let backoffSchedule: [TimeInterval] = [1, 2, 4, 8, 15]

    // Subjects are only ever sent to from this actor's executor.
    private nonisolated let eventSubject = PassthroughSubject<GatewayEvent, Never>()
    private nonisolated let stateSubject = CurrentValueSubject<ConnectionState, Never>(.idle)

    /// Every gateway event (notifications with method == "event").
    public nonisolated var events: AnyPublisher<GatewayEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    /// Connection state changes (replays current value on subscribe).
    public nonisolated var statePublisher: AnyPublisher<ConnectionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    public nonisolated var connectionState: ConnectionState { stateSubject.value }

    /// AsyncStream view over the same event flow.
    public nonisolated func eventStream() -> AsyncStream<GatewayEvent> {
        let subject = eventSubject
        return AsyncStream { continuation in
            let cancellable = subject.sink { continuation.yield($0) }
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    private let urlSession: URLSession
    private var socket: URLSessionWebSocketTask?
    private var socketGeneration = 0
    private var url: URL?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var pendingTimeouts: [Int: Task<Void, Never>] = [:]
    private var pendingMethods: [Int: String] = [:]
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var userInitiatedClose = false
    /// Invoked (on a detached task) after a successful automatic reconnect,
    /// so the owner can re-check /api/status and session.resume open sessions.
    private var reconnectHandler: (@Sendable () async -> Void)?

    public init(urlSession: URLSession = URLSession(configuration: .default)) {
        self.urlSession = urlSession
    }

    public func setReconnectHandler(_ handler: (@Sendable () async -> Void)?) {
        reconnectHandler = handler
    }

    // MARK: Connect / disconnect

    public func connect(url: URL) async throws {
        userInitiatedClose = false
        reconnectTask?.cancel()
        reconnectTask = nil
        self.url = url
        try await openSocket(url: url)
    }

    public func disconnect() {
        userInitiatedClose = true
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        failAllPending(with: RPCError.notConnected)
        setState(.closed)
    }

    private func openSocket(url: URL) async throws {
        setState(.connecting)
        socket?.cancel(with: .goingAway, reason: nil)
        receiveTask?.cancel()

        socketGeneration += 1
        let generation = socketGeneration
        let task = urlSession.webSocketTask(with: url)
        task.maximumMessageSize = 32 * 1024 * 1024
        socket = task
        task.resume()

        // No delegate: confirm the handshake by racing the FIRST server frame
        // against a deadline. The gateway pushes a `gateway.ready` event as
        // soon as it accepts the socket (see AGENT_PROTOCOL.md), and a ping
        // cannot be used here: URLSessionWebSocketTask only surfaces the pong
        // callback after earlier incoming frames are consumed via receive(),
        // so a ping parked behind the unread gateway.ready frame never fires.
        let firstFrame: URLSessionWebSocketTask.Message
        do {
            firstFrame = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                group.addTask {
                    do {
                        return try await task.receive()
                    } catch {
                        throw RPCError.connectFailed(error.localizedDescription)
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(Self.connectTimeout * 1_000_000_000))
                    throw RPCError.connectFailed("timed out after \(Int(Self.connectTimeout))s")
                }
                do {
                    guard let first = try await group.next() else {
                        throw RPCError.connectFailed("socket closed during handshake")
                    }
                    group.cancelAll()
                    return first
                } catch {
                    group.cancelAll()
                    // Unblocks the parked receive() child so the group can exit.
                    task.cancel(with: .goingAway, reason: nil)
                    throw error
                }
            }
        } catch {
            if socketGeneration == generation {
                socket = nil
                setState(.failed(error.localizedDescription))
            }
            throw error
        }

        setState(.open)
        switch firstFrame {
        case .string(let text):
            handleFrame(Data(text.utf8))
        case .data(let data):
            handleFrame(data)
        @unknown default:
            break
        }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task: task, generation: generation)
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask, generation: Int) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard socketGeneration == generation else { return }
                switch message {
                case .string(let text):
                    handleFrame(Data(text.utf8))
                case .data(let data):
                    handleFrame(data)
                @unknown default:
                    break
                }
            } catch {
                guard socketGeneration == generation, !Task.isCancelled else { return }
                handleDrop(closeCode: task.closeCode, error: error)
                return
            }
        }
    }

    // MARK: Frame handling

    private func handleFrame(_ data: Data) {
        guard let frame = JSONValue.decode(data) else { return }

        // Response: matched strictly by id (out-of-order safe).
        if let id = frame["id"].int {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            pendingTimeouts.removeValue(forKey: id)?.cancel()
            pendingMethods.removeValue(forKey: id)
            let errorBody = frame["error"]
            if !errorBody.isNull {
                continuation.resume(throwing: RPCError.server(
                    code: errorBody["code"].int ?? -1,
                    message: errorBody["message"].string ?? "Hermes RPC failed"
                ))
            } else {
                continuation.resume(returning: frame["result"])
            }
            return
        }

        // Notification: {"method":"event","params":{type, session_id, payload}}
        if frame["method"].string == "event",
           let event = GatewayEvent(notificationParams: frame["params"]) {
            eventSubject.send(event)
        }
    }

    private func handleDrop(closeCode: URLSessionWebSocketTask.CloseCode, error: Error) {
        socket = nil
        failAllPending(with: RPCError.transport(error.localizedDescription))
        if userInitiatedClose {
            setState(.closed)
            return
        }
        // 4401/4403 = token rejected; reconnecting with the same token can never succeed.
        if closeCode.rawValue == 4401 || closeCode.rawValue == 4403 {
            setState(.failed("gateway rejected session token (\(closeCode.rawValue))"))
            return
        }
        startReconnectLoop()
    }

    private func startReconnectLoop() {
        guard reconnectTask == nil, let url else {
            if url == nil { setState(.closed) }
            return
        }
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop(url: url)
        }
    }

    private func runReconnectLoop(url: URL) async {
        var attempt = 0
        while !Task.isCancelled && !userInitiatedClose {
            let delay = Self.backoffSchedule[min(attempt, Self.backoffSchedule.count - 1)]
            setState(.reconnecting(attempt: attempt + 1))
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch { break }
            if Task.isCancelled || userInitiatedClose { break }
            do {
                try await openSocket(url: url)
                reconnectTask = nil
                if let handler = reconnectHandler {
                    Task.detached { await handler() }
                }
                return
            } catch {
                attempt += 1
            }
        }
        reconnectTask = nil
    }

    private func failAllPending(with error: Error) {
        let waiting = pending
        pending.removeAll()
        pendingMethods.removeAll()
        for task in pendingTimeouts.values { task.cancel() }
        pendingTimeouts.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }

    private func setState(_ state: ConnectionState) {
        guard stateSubject.value != state else { return }
        stateSubject.send(state)
    }

    // MARK: Requests

    /// Send a JSON-RPC request and await its response (matched by id).
    @discardableResult
    public func request(
        _ method: String,
        params: JSONValue = .object([:]),
        timeout: TimeInterval = JSONRPCClient.defaultRequestTimeout
    ) async throws -> JSONValue {
        guard let socket, socket.state == .running else { throw RPCError.notConnected }

        nextID += 1
        let id = nextID
        let frame: JSONValue = .object([
            "jsonrpc": "2.0",
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ])
        let text = frame.encodedString()

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            pendingMethods[id] = method
            if timeout > 0 {
                pendingTimeouts[id] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.timeoutRequest(id: id)
                }
            }
            socket.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { await self?.failRequest(id: id, error: RPCError.transport(error.localizedDescription)) }
            }
        }
    }

    private func timeoutRequest(id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        pendingTimeouts.removeValue(forKey: id)
        let method = pendingMethods.removeValue(forKey: id) ?? "?"
        continuation.resume(throwing: RPCError.timeout(method: method))
    }

    private func failRequest(id: Int, error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        pendingTimeouts.removeValue(forKey: id)?.cancel()
        pendingMethods.removeValue(forKey: id)
        continuation.resume(throwing: error)
    }
}
