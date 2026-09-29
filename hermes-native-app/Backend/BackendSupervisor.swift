//
//  BackendSupervisor.swift
//  hermes-native-app
//
//  Spawns and supervises the local hermes backend (replaces the Electron main
//  process). Recipe verified against apps/desktop/electron/{main,backend-*,
//  dashboard-token}.cjs and live v0.17.0:
//    hermes dashboard --no-open --host 127.0.0.1 --port 0
//  then stdout-scan for "HERMES_DASHBOARD_READY port=<N>", poll /api/status,
//  scrape window.__HERMES_SESSION_TOKEN__ from GET /.
//

import Foundation
import Synchronization

/// Everything a client needs to talk to the spawned backend.
public struct BackendConnection: Sendable, Equatable {
    public let baseURL: URL
    public let wsURL: URL
    public let token: String
    public let port: Int
}

public actor BackendSupervisor {

    public enum SupervisorError: Error, LocalizedError {
        case runtimeNotFound
        case launchFailed(String)
        case readyTimeout(String)
        case exitedBeforeReady(Int32)
        case statusProbeTimeout
        /// Served token != pinned token while our child is dead: a process we
        /// did not spawn owns the port. Never adopt its token.
        case foreignBackend(port: Int)

        public var errorDescription: String? {
            switch self {
            case .runtimeNotFound:
                return "Could not find a Hermes runtime (managed install or 'hermes' on PATH)."
            case .launchFailed(let detail):
                return "Could not launch the Hermes backend: \(detail)"
            case .readyTimeout(let detail):
                return "Timed out waiting for the Hermes backend to start. \(detail)"
            case .exitedBeforeReady(let status):
                return "Hermes backend exited before announcing its port (status \(status)). See ~/Library/Logs/HermesDesktop/backend.log."
            case .statusProbeTimeout:
                return "Hermes backend announced a port but /api/status never became ready."
            case .foreignBackend(let port):
                return "Port \(port) is served by a Hermes process this app did not spawn; refusing its session token."
            }
        }
    }

    /// UserDefaults key holding an absolute path to a hermes executable override.
    public static let runtimeOverrideDefaultsKey = "HermesBackendExecutableOverride"
    /// First launch may build the web SPA before binding — allow 90 s.
    public static let readyTimeout: TimeInterval = 90
    private static let statusPollTimeout: TimeInterval = 60

    private var process: Process?
    private var connection: BackendConnection?
    private var pinnedToken: String?
    private var userInitiatedStop = false
    private var logHandle: FileHandle?
    private var exitHandler: (@Sendable (Int32) -> Void)?
    private let probeSession: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        probeSession = URLSession(configuration: config)
    }

    /// Called when the child exits without stop() having been requested.
    public func setExitHandler(_ handler: (@Sendable (Int32) -> Void)?) {
        exitHandler = handler
    }

    public var currentConnection: BackendConnection? { connection }

    public func isChildRunning() -> Bool { process?.isRunning ?? false }

    // MARK: Lifecycle

    /// Resolve runtime, spawn, handshake. Returns the ready connection.
    public func start(workspace: URL? = nil) async throws -> BackendConnection {
        if let connection, isChildRunning() { return connection }

        userInitiatedStop = false
        let hermesHome = Self.resolveHermesHome()
        guard let runtime = Self.resolveRuntime(hermesHome: hermesHome) else {
            throw SupervisorError.runtimeNotFound
        }

        let token = Self.mintToken()
        pinnedToken = token
        let cwd = workspace ?? FileManager.default.homeDirectoryForCurrentUser

        let child = Process()
        child.executableURL = runtime.executable
        // v0.17 has no 'serve' subcommand; 'dashboard --no-open' is the
        // wire-identical fallback that works on all versions.
        child.arguments = runtime.leadingArguments + [
            "dashboard", "--no-open", "--host", "127.0.0.1", "--port", "0",
        ]
        child.currentDirectoryURL = runtime.workingDirectory ?? cwd

        var env = ProcessInfo.processInfo.environment
        env["HERMES_HOME"] = hermesHome.path
        env["HERMES_DASHBOARD_SESSION_TOKEN"] = token
        env["HERMES_DESKTOP"] = "1"
        env["TERMINAL_CWD"] = cwd.path
        env["PATH"] = Self.repairedPATH(hermesHome: hermesHome, current: env["PATH"])
        child.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe

        let log = Self.openBackendLog()
        logHandle = log
        Self.log(log, "launching: \(runtime.executable.path) \(child.arguments!.joined(separator: " "))")
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            log?.write(data)
        }

        let ready = ReadySignal()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            log?.write(data)
            ready.consume(data)
        }
        child.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            ready.fail(SupervisorError.exitedBeforeReady(status))
            Task { await self?.handleChildExit(status: status) }
        }

        do {
            try child.run()
        } catch {
            throw SupervisorError.launchFailed(error.localizedDescription)
        }
        process = child
        Self.lastChildPID.withLock { $0 = child.processIdentifier }

        // 1. Stdout line-scan for ^HERMES_DASHBOARD_READY port=(\d+)$ (90 s).
        let port: Int
        do {
            port = try await ready.wait(timeout: Self.readyTimeout)
        } catch {
            await stop()
            throw error
        }

        guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
            await stop()
            throw SupervisorError.launchFailed("bad port \(port)")
        }

        do {
            // 2. Poll /api/status with the pinned token until 200.
            try await pollStatus(baseURL: baseURL, token: token)
            // 3. GET / and scrape window.__HERMES_SESSION_TOKEN__; the served
            //    token is authoritative. Foreign token + dead child => abort.
            let served = await scrapeServedToken(baseURL: baseURL)
            var effectiveToken = token
            if let served, served != token {
                if isChildRunning() {
                    Self.log(log, "adopting served session token (env pin did not survive spawn)")
                    effectiveToken = served
                } else {
                    throw SupervisorError.foreignBackend(port: port)
                }
            }

            var wsComponents = URLComponents()
            wsComponents.scheme = "ws"
            wsComponents.host = "127.0.0.1"
            wsComponents.port = port
            wsComponents.path = "/api/ws"
            wsComponents.queryItems = [URLQueryItem(name: "token", value: effectiveToken)]
            guard let wsURL = wsComponents.url else {
                throw SupervisorError.launchFailed("could not build ws URL")
            }

            let conn = BackendConnection(baseURL: baseURL, wsURL: wsURL, token: effectiveToken, port: port)
            connection = conn
            Self.log(log, "ready: port=\(port)")
            return conn
        } catch {
            await stop()
            throw error
        }
    }

    /// SIGTERM, wait up to 5 s, then SIGKILL. Call from applicationWillTerminate.
    public func stop() async {
        userInitiatedStop = true
        connection = nil
        guard let child = process else { return }
        process = nil
        Self.lastChildPID.withLock { $0 = nil }
        guard child.isRunning else { return }
        child.terminate() // SIGTERM
        let deadline = Date().addingTimeInterval(5)
        while child.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
        }
        Self.log(logHandle, "stopped")
    }

    /// PID of the running backend child, mirrored outside the actor so quit
    /// can reap it without touching the actor or the main-actor executor.
    nonisolated private static let lastChildPID = Mutex<pid_t?>(nil)

    /// Synchronous best-effort child kill for app termination. Safe from any
    /// thread; no actor hop, no async — `applicationWillTerminate` runs on a
    /// path where main-actor tasks may never get scheduled again.
    nonisolated public static func emergencySyncStop() {
        guard let pid = lastChildPID.withLock({ $0 }) else { return }
        lastChildPID.withLock { $0 = nil }
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return } // exited
            usleep(100_000)
        }
        kill(pid, SIGKILL)
    }

    private func handleChildExit(status: Int32) {
        Self.log(logHandle, "backend exited status=\(status)")
        process = nil
        Self.lastChildPID.withLock { $0 = nil }
        connection = nil
        if !userInitiatedStop {
            exitHandler?(status)
        }
    }

    // MARK: Handshake steps

    private func pollStatus(baseURL: URL, token: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/status"))
        request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token")
        let deadline = Date().addingTimeInterval(Self.statusPollTimeout)
        while Date() < deadline {
            if !isChildRunning() { throw SupervisorError.exitedBeforeReady(process?.terminationStatus ?? -1) }
            if let (_, response) = try? await probeSession.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        throw SupervisorError.statusProbeTimeout
    }

    private func scrapeServedToken(baseURL: URL) async -> String? {
        guard let (data, response) = try? await probeSession.data(from: baseURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return nil }
        return Self.extractInjectedToken(html: html)
    }

    /// Matches `window.__HERMES_SESSION_TOKEN__ = "<token>"` in served index.html.
    static func extractInjectedToken(html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"window\.__HERMES_SESSION_TOKEN__\s*=\s*"((?:\\.|[^"\\])*)""#
        ) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let tokenRange = Range(match.range(at: 1), in: html) else { return nil }
        let token = String(html[tokenRange])
        return token.isEmpty ? nil : token
    }

    // MARK: Runtime resolution

    struct RuntimeCommand {
        let executable: URL
        /// e.g. ["-m", "hermes_cli.main"] when launching via venv python.
        let leadingArguments: [String]
        let workingDirectory: URL?
    }

    static func resolveHermesHome() -> URL {
        if let fromEnv = ProcessInfo.processInfo.environment["HERMES_HOME"], !fromEnv.isEmpty {
            return URL(fileURLWithPath: (fromEnv as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
    }

    /// Resolution order (mirrors Electron): explicit override -> managed install
    /// (~/.hermes/hermes-agent with .hermes-bootstrap-complete) -> `hermes` on
    /// the repaired PATH (probed with --version).
    static func resolveRuntime(hermesHome: URL) -> RuntimeCommand? {
        let fm = FileManager.default

        if let override = UserDefaults.standard.string(forKey: runtimeOverrideDefaultsKey),
           !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if fm.isExecutableFile(atPath: url.path) {
                return RuntimeCommand(executable: url, leadingArguments: [], workingDirectory: nil)
            }
        }

        let managedRoot = hermesHome.appendingPathComponent("hermes-agent")
        let marker = managedRoot.appendingPathComponent(".hermes-bootstrap-complete")
        if fm.fileExists(atPath: marker.path) {
            let venvHermes = managedRoot.appendingPathComponent("venv/bin/hermes")
            if fm.isExecutableFile(atPath: venvHermes.path) {
                return RuntimeCommand(executable: venvHermes, leadingArguments: [], workingDirectory: managedRoot)
            }
            let venvPython = managedRoot.appendingPathComponent("venv/bin/python")
            if fm.isExecutableFile(atPath: venvPython.path) {
                return RuntimeCommand(
                    executable: venvPython,
                    leadingArguments: ["-m", "hermes_cli.main"],
                    workingDirectory: managedRoot
                )
            }
        }

        let path = repairedPATH(hermesHome: hermesHome, current: ProcessInfo.processInfo.environment["PATH"])
        for dir in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("hermes")
            if fm.isExecutableFile(atPath: candidate.path), probeVersion(executable: candidate) {
                return RuntimeCommand(executable: candidate, leadingArguments: [], workingDirectory: nil)
            }
        }
        return nil
    }

    /// `hermes --version` exit-0 probe (10 s cap) — filters out broken shims.
    static func probeVersion(executable: URL) -> Bool {
        let probe = Process()
        probe.executableURL = executable
        probe.arguments = ["--version"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
        } catch {
            return false
        }
        let deadline = Date().addingTimeInterval(10)
        while probe.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if probe.isRunning {
            probe.terminate()
            return false
        }
        return probe.terminationStatus == 0
    }

    /// Finder-launched apps inherit a bare PATH; prepend the managed node/venv
    /// bins and Homebrew dirs, then the inherited entries, then system dirs.
    static func repairedPATH(hermesHome: URL, current: String?) -> String {
        var entries: [String] = [
            hermesHome.appendingPathComponent("node/bin").path,
            hermesHome.appendingPathComponent("hermes-agent/venv/bin").path,
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
        ]
        if let current { entries.append(contentsOf: current.split(separator: ":").map(String.init)) }
        entries.append(contentsOf: ["/usr/sbin", "/usr/bin", "/sbin", "/bin"])
        var seen = Set<String>()
        return entries.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    // MARK: Token / logging

    /// 32 random bytes, base64url (no padding) — server adopts it via env.
    static func mintToken() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        for _ in 0..<4 {
            var word = generator.next() as UInt64
            for _ in 0..<8 {
                bytes.append(UInt8(truncatingIfNeeded: word))
                word >>= 8
            }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func backendLogURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/HermesDesktop/backend.log")
    }

    private static func openBackendLog() -> FileHandle? {
        let url = backendLogURL()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    private static func log(_ handle: FileHandle?, _ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        handle?.write(Data("[\(stamp)] [supervisor] \(message)\n".utf8))
    }
}

/// Thread-safe stdout line scanner + one-shot ready signal. The readability
/// handler runs on a Dispatch queue while the waiter suspends in the actor,
/// so all state lives behind a lock.
private final class ReadySignal: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var result: Result<Int, Error>?
    private var continuation: CheckedContinuation<Int, Error>?

    func consume(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        var resumeWith: Result<Int, Error>?
        lock.lock()
        if result == nil {
            buffer += chunk
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
                buffer = String(buffer[buffer.index(after: newline)...])
                if line.hasPrefix("HERMES_DASHBOARD_READY port="),
                   let port = Int(line.dropFirst("HERMES_DASHBOARD_READY port=".count)), port > 0 {
                    result = .success(port)
                    resumeWith = result
                    break
                }
            }
        }
        let cont = resumeWith != nil ? continuation : nil
        if resumeWith != nil { continuation = nil }
        lock.unlock()
        if let cont, case .success(let port)? = resumeWith {
            cont.resume(returning: port)
        }
    }

    func fail(_ error: Error) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = .failure(error)
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }

    func wait(timeout: TimeInterval) async throws -> Int {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.fail(BackendSupervisor.SupervisorError.readyTimeout(
                "No port announcement within \(Int(timeout))s (first launch may build the web UI)."
            ))
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                cont.resume(with: result)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }
}
