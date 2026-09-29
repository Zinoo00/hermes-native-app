import AppKit
import Combine
import UniformTypeIdentifiers

/// Chat content pane: transcript thread + context strip + composer, bound to
/// `HermesStore.focusedSession`. Adopts `ConversationMenuActions` so the
/// Conversation menu lights up while a conversation is focused.
final class ChatContentViewController: NSViewController,
                                       ChatComposerViewDelegate,
                                       ConversationMenuActions,
                                       NSMenuItemValidation {

    private let store = AppEnvironment.shared.store

    private let transcriptView = ChatTranscriptView()
    private let contextStrip = ChatContextStripView()
    private let composer = ChatComposerView()
    private let emptyState = ChatEmptyStateView()
    private let bottomColumn = NSStackView()

    private var cancellables = Set<AnyCancellable>()
    private var sessionCancellables = Set<AnyCancellable>()

    private var contextReferences: [ChatContextReference] = []
    private var permissionMode: ChatPermissionMode = .askFirst
    private var autoAnsweredApprovals = Set<UUID>()
    private var addContextPopover: NSPopover?

    /// Model choice applied to the NEXT session.create (per-session model
    /// switching mid-conversation has no RPC).
    private var pendingProvider: String?
    private var pendingModel: String?
    private var pendingEffort: String?

    private static let permissionModeKey = "hermes.permissionMode"

    init() {
        super.init(nibName: nil, bundle: nil)
        if let raw = UserDefaults.standard.string(forKey: Self.permissionModeKey),
           let saved = ChatPermissionMode(rawValue: raw), saved.isSelectable {
            permissionMode = saved
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - View lifecycle

    override func loadView() {
        let root = ChatBackgroundView()

        composer.delegate = self
        composer.permissionControl.mode = permissionMode
        contextStrip.onRemoveChip = { [weak self] reference in
            self?.removeContextReference(reference)
        }
        emptyState.onNewConversation = { [weak self] in self?.startNewConversation() }

        bottomColumn.orientation = .vertical
        bottomColumn.alignment = .leading
        bottomColumn.spacing = 8
        bottomColumn.translatesAutoresizingMaskIntoConstraints = false
        bottomColumn.addArrangedSubview(contextStrip)
        bottomColumn.addArrangedSubview(composer)

        root.addSubview(transcriptView)
        root.addSubview(bottomColumn)
        root.addSubview(emptyState)

        let preferredWidth = bottomColumn.widthAnchor.constraint(equalToConstant: 780)
        preferredWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            transcriptView.topAnchor.constraint(equalTo: root.topAnchor),
            transcriptView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcriptView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            bottomColumn.topAnchor.constraint(equalTo: transcriptView.bottomAnchor, constant: 6),
            bottomColumn.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bottomColumn.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 36),
            bottomColumn.widthAnchor.constraint(lessThanOrEqualToConstant: 780),
            preferredWidth,
            bottomColumn.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),

            contextStrip.widthAnchor.constraint(equalTo: bottomColumn.widthAnchor),
            composer.widthAnchor.constraint(equalTo: bottomColumn.widthAnchor),

            emptyState.topAnchor.constraint(equalTo: root.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bind()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if store.focusedSession != nil {
            view.window?.makeFirstResponder(composer.textView)
        } else {
            // Keep this VC in the responder chain so the Conversation menu
            // validates even before a session is focused.
            view.window?.makeFirstResponder(view)
        }
    }

    // MARK: - Store bindings

    private func bind() {
        store.$focusedSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in self?.attach(session) }
            .store(in: &cancellables)

        store.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.emptyState.update(connectionState: state) }
            .store(in: &cancellables)

        // Continuity divider needs the stored session's source metadata.
        store.$sessions
            .combineLatest(store.$focusedSession)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions, session in
                self?.updateContinuity(sessions: sessions, session: session)
            }
            .store(in: &cancellables)

        // Model picker from real backend data.
        store.$modelOptions
            .combineLatest(store.$modelInfo)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.rebuildModelMenu() }
            .store(in: &cancellables)

        // Permission mode drives approval auto-answers (client-enforced; the
        // backend has no named modes).
        store.$attentionItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.autoAnswerApprovals(items) }
            .store(in: &cancellables)

        Theme.shared.onAccentChange(storeIn: &cancellables) { [weak self] in self?.refreshAccent() }
    }

    private func attach(_ session: ChatSession?) {
        sessionCancellables.removeAll()

        let hasSession = session != nil
        emptyState.isHidden = hasSession
        transcriptView.isHidden = !hasSession
        bottomColumn.isHidden = !hasSession

        guard let session else {
            transcriptView.apply([])
            transcriptView.setSubagents([])
            transcriptView.setStatus(nil)
            contextStrip.setUsage(contextUsed: nil, contextMax: nil)
            return
        }

        session.$transcript
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] items in self?.transcriptView.apply(items) }
            .store(in: &sessionCancellables)

        session.$subagents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rows in self?.transcriptView.setSubagents(rows) }
            .store(in: &sessionCancellables)

        session.$usage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] usage in
                self?.contextStrip.setUsage(contextUsed: usage?.contextUsed,
                                            contextMax: usage?.contextMax)
            }
            .store(in: &sessionCancellables)

        session.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in self?.composer.setRunning(running) }
            .store(in: &sessionCancellables)

        session.$isThinking
            .combineLatest(session.$statusText, session.$isRunning)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] thinking, status, running in
                if let status, !status.isEmpty {
                    self?.transcriptView.setStatus(status)
                } else if thinking, running {
                    self?.transcriptView.setStatus("Thinking…")
                } else {
                    self?.transcriptView.setStatus(nil)
                }
            }
            .store(in: &sessionCancellables)

        session.$info
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateModelTitle() }
            .store(in: &sessionCancellables)

        transcriptView.scrollToBottomSoon()
        view.window?.makeFirstResponder(composer.textView)
    }

    private func updateContinuity(sessions: [SessionSummary], session: ChatSession?) {
        guard let storedID = session?.storedSessionID,
              let summary = sessions.first(where: { $0.id == storedID }),
              let source = summary.source,
              ChatPlatformBadge.isMessagingPlatform(source) else {
            transcriptView.setContinuity(text: nil, monogram: "›")
            return
        }
        let platform = ChatPlatformBadge.displayName(for: source)
        transcriptView.setContinuity(
            text: "Continued from \(platform) — picked up here on your Mac",
            monogram: ChatPlatformBadge.monogram(for: source))
    }

    private func refreshAccent() {
        Self.markNeedsDisplayRecursively(view)
    }

    private static func markNeedsDisplayRecursively(_ view: NSView) {
        view.needsDisplay = true
        for subview in view.subviews {
            markNeedsDisplayRecursively(subview)
        }
    }

    // MARK: - Empty state / session creation

    private func startNewConversation() {
        Task {
            await store.newSession(model: pendingModel,
                                   provider: pendingProvider,
                                   reasoningEffort: pendingEffort?.lowercased())
        }
    }

    // MARK: - Submit / interrupt

    private func submitComposer() {
        guard let session = store.focusedSession else { return }
        let body = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = contextReferences.map(\.token)
        guard !body.isEmpty else { return }

        let full = (tokens + [body]).joined(separator: " ")
        composer.clear()
        setContextReferences([])

        Task { [weak self] in
            do {
                try await session.submit(text: full)
            } catch ChatSessionError.busy {
                self?.presentBusyChoice(pendingText: full, session: session)
            } catch {
                self?.composer.text = full
                self?.presentError("Message not sent", error.localizedDescription)
            }
        }
    }

    /// prompt.submit hit 4009 — offer steer or cancel.
    private func presentBusyChoice(pendingText: String, session: ChatSession) {
        let alert = NSAlert()
        alert.messageText = "Hermes is still working"
        alert.informativeText = "The current turn is still running. Steer it with your message, or wait for it to finish."
        alert.addButton(withTitle: "Steer Into Turn")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task { [weak self] in
                do { _ = try await session.steer(text: pendingText) }
                catch { self?.presentError("Steer failed", error.localizedDescription) }
            }
        } else {
            composer.text = pendingText
        }
    }

    private func presentError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - Approval auto-answer (permission mode)

    private func autoAnswerApprovals(_ items: [AttentionItem]) {
        guard let choice = permissionMode.autoApprovalChoice else { return }
        let focusedLiveID = store.focusedSession?.liveSessionID
        for item in items {
            guard case .approval = item.kind,
                  !autoAnsweredApprovals.contains(item.id),
                  item.sessionID == nil || item.sessionID == focusedLiveID else { continue }
            autoAnsweredApprovals.insert(item.id)
            Task { await store.answerApproval(item, choice: choice) }
        }
        // Keep the answered-set from growing without bound.
        if autoAnsweredApprovals.count > 200 {
            let live = Set(items.map(\.id))
            autoAnsweredApprovals.formIntersection(live)
        }
    }

    // MARK: - Context references

    private func setContextReferences(_ references: [ChatContextReference]) {
        contextReferences = references
        contextStrip.setReferences(references)
    }

    private func addContextReference(_ reference: ChatContextReference) {
        guard !contextReferences.contains(reference) else { return }
        setContextReferences(contextReferences + [reference])
        ChatRecentContextStore.remember(reference)
    }

    private func removeContextReference(_ reference: ChatContextReference) {
        setContextReferences(contextReferences.filter { $0 != reference })
    }

    // MARK: - ChatComposerViewDelegate

    func composerSubmitRequested() { submitComposer() }

    func composerStopRequested() {
        guard let session = store.focusedSession else { return }
        Task { await session.interrupt() }
    }

    func composerTextDidChange() {}

    func composerCycleModeRequested() {
        composer.permissionControl.cycle()
    }

    func composerPermissionModeChanged(_ mode: ChatPermissionMode) {
        permissionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.permissionModeKey)
        // Apply immediately to anything already waiting.
        autoAnswerApprovals(store.attentionItems)
    }

    func composerAttachFilesRequested() {
        attachViaOpenPanel(imagesOnly: false)
    }

    func composerAttachImageRequested() {
        attachViaOpenPanel(imagesOnly: true)
    }

    private func attachViaOpenPanel(imagesOnly: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = !imagesOnly
        if imagesOnly { panel.allowedContentTypes = [.image] }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            attachFile(at: url)
        }
    }

    /// rpc image.attach/file.attach {path} + "@file:<path>" token in the input.
    private func attachFile(at url: URL) {
        let path = url.path
        let isImage = (try? url.resourceValues(forKeys: [.contentTypeKey]))?
            .contentType?.conforms(to: .image) ?? false
        let method = isImage ? "image.attach" : "file.attach"
        composer.appendToken("@file:\(path)")
        Task { [weak self, store] in
            do {
                _ = try await store.rpc.request(method, params: .object(["path": .string(path)]),
                                                timeout: 60)
            } catch {
                self?.presentError("Attach failed", error.localizedDescription)
            }
        }
    }

    func composerAddLinkRequested() {
        guard let url = promptForText(title: "Add a link",
                                      message: "The URL is referenced in your next message.",
                                      placeholder: "https://…") else { return }
        composer.appendToken(url)
    }

    func composerInsertSkillRequested(_ name: String) {
        composer.appendToken(name)
    }

    func composerSpawnSubagentRequested() {
        // No dedicated RPC — subagents are spawned by the agent. Seed the
        // prompt instead.
        if composer.text.isEmpty {
            composer.text = "Spawn a subagent to "
        } else {
            composer.appendToken("— spawn a subagent for this.")
        }
        view.window?.makeFirstResponder(composer.textView)
    }

    func composerScheduleRequested() {
        // Schedules live in the Automations section.
        NSApp.sendAction(#selector(AppDelegate.goToAutomations(_:)), to: nil, from: self)
    }

    func composerAddContextRequested(relativeTo anchor: NSView) {
        addContextPopover?.close()
        let controller = ChatAddContextPopoverController { [weak self] action in
            self?.addContextPopover?.close()
            self?.handleAddContext(action)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        addContextPopover = popover
    }

    private func handleAddContext(_ action: ChatAddContextPopoverController.Action) {
        switch action {
        case .file:
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            guard panel.runModal() == .OK else { return }
            for url in panel.urls {
                addContextReference(ChatContextReference(
                    label: url.lastPathComponent, token: "@file:\(url.path)"))
            }
        case .folder:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            addContextReference(ChatContextReference(
                label: url.lastPathComponent, token: "@folder:\(url.path)"))
        case .gitDiff:
            addContextReference(ChatContextReference(label: "git diff", token: "@diff"))
        case .pasteURL:
            let pasted = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate: String?
            if let pasted, pasted.hasPrefix("http://") || pasted.hasPrefix("https://") {
                candidate = pasted
            } else {
                candidate = promptForText(title: "Paste URL",
                                          message: "Pulled into the message as context.",
                                          placeholder: "https://…")
            }
            if let candidate, !candidate.isEmpty {
                let label = URL(string: candidate)?.host ?? candidate
                addContextReference(ChatContextReference(label: label, token: candidate))
            }
        case .recent(let reference):
            addContextReference(reference)
        }
    }

    var composerSkillNames: [String] {
        store.skills.map(\.name)
    }

    var composerToolsets: [(name: String, toolCount: Int)] {
        guard let tools = store.focusedSession?.info?.toolsByToolset else { return [] }
        return tools.keys.sorted().map { ($0, tools[$0]?.count ?? 0) }
    }

    // MARK: - Model picker

    private func rebuildModelMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Model", action: nil, keyEquivalent: "")) // pulls-down title slot

        let options = store.modelOptions
        let currentModel = pendingModel ?? options?.currentModel ?? store.modelInfo?.model
        let currentProvider = pendingProvider ?? options?.currentProvider ?? store.modelInfo?.provider

        var homeProviders: [ModelProviderOption] = []
        var otherProviders: [ModelProviderOption] = []
        for provider in options?.providers ?? [] {
            if provider.slug == currentProvider || provider.isCurrent {
                homeProviders.append(provider)
            } else {
                otherProviders.append(provider)
            }
        }

        var addedAny = false
        for provider in homeProviders {
            for model in provider.models.prefix(8) {
                menu.addItem(modelItem(provider: provider.slug, model: model,
                                       checked: model == currentModel))
                addedAny = true
            }
        }
        if !addedAny, let currentModel {
            menu.addItem(modelItem(provider: currentProvider ?? "", model: currentModel, checked: true))
            addedAny = true
        }
        if !addedAny {
            let placeholder = NSMenuItem(title: "No models reported", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        }

        menu.addItem(.separator())

        // Effort ▸
        let effortItem = NSMenuItem(title: "Effort", action: nil, keyEquivalent: "")
        let effortMenu = NSMenu()
        let currentEffort = currentEffortDisplay()
        for effort in ["Low", "Medium", "High", "Max"] {
            let item = NSMenuItem(title: effort, action: #selector(effortPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = effort
            item.state = (effort == currentEffort) ? .on : .off
            effortMenu.addItem(item)
        }
        effortItem.submenu = effortMenu
        menu.addItem(effortItem)

        // More models ▸ (other providers)
        if !otherProviders.isEmpty {
            let moreItem = NSMenuItem(title: "More models", action: nil, keyEquivalent: "")
            let moreMenu = NSMenu()
            for provider in otherProviders {
                let header = NSMenuItem(title: provider.name, action: nil, keyEquivalent: "")
                header.isEnabled = false
                moreMenu.addItem(header)
                for model in provider.models.prefix(8) {
                    let item = modelItem(provider: provider.slug, model: model,
                                         checked: model == currentModel)
                    item.indentationLevel = 1
                    moreMenu.addItem(item)
                }
                if let total = provider.totalModels, total > provider.models.count {
                    let more = NSMenuItem(title: "…\(total - provider.models.count) more",
                                          action: nil, keyEquivalent: "")
                    more.isEnabled = false
                    more.indentationLevel = 1
                    moreMenu.addItem(more)
                }
            }
            moreItem.submenu = moreMenu
            menu.addItem(moreItem)
        }

        composer.modelButton.menu = menu
        updateModelTitle()
    }

    private func modelItem(provider: String, model: String, checked: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: Self.shortModelName(model),
                              action: #selector(modelPicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ["provider": provider, "model": model]
        item.state = checked ? .on : .off
        return item
    }

    @objc private func modelPicked(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let model = info["model"] else { return }
        pendingModel = model
        pendingProvider = info["provider"]
        rebuildModelMenu()
    }

    @objc private func effortPicked(_ sender: NSMenuItem) {
        pendingEffort = sender.representedObject as? String
        rebuildModelMenu()
    }

    private func currentEffortDisplay() -> String? {
        if let pendingEffort { return pendingEffort }
        if let effort = store.focusedSession?.info?.reasoningEffort, !effort.isEmpty {
            return effort.capitalized
        }
        return nil
    }

    private func updateModelTitle() {
        let model = pendingModel
            ?? store.focusedSession?.info?.model
            ?? store.modelOptions?.currentModel
            ?? store.modelInfo?.model
        composer.setModelTitle(Self.shortModelName(model ?? "Model"),
                               effort: currentEffortDisplay())
    }

    private static func shortModelName(_ model: String) -> String {
        var name = model
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        if name.count > 26 {
            name = String(name.prefix(25)) + "…"
        }
        return name
    }

    // MARK: - ConversationMenuActions

    @objc func sendConversationMessage(_ sender: Any?) {
        submitComposer()
    }

    @objc func interruptConversation(_ sender: Any?) {
        composerStopRequested()
    }

    @objc func branchConversation(_ sender: Any?) {
        guard let session = store.focusedSession, let liveID = session.liveSessionID else { return }
        Task { [weak self, store] in
            do {
                let result = try await store.rpc.request("session.branch", params: .object([
                    "session_id": .string(liveID),
                ]), timeout: 60)
                if let storedID = result.first(["stored_session_id", "resumed"]).string {
                    await self?.store.selectSession(storedID: storedID)
                }
                await self?.store.refreshSessions()
            } catch {
                self?.presentError("Branch failed", error.localizedDescription)
            }
        }
    }

    @objc func renameConversation(_ sender: Any?) {
        guard let session = store.focusedSession, let storedID = session.storedSessionID else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Conversation"
        alert.informativeText = "The new title syncs everywhere."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = session.title ?? ""
        field.placeholderString = "Conversation title"
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task { await store.renameSession(id: storedID, title: title) }
    }

    @objc func archiveConversation(_ sender: Any?) {
        guard let storedID = store.focusedSession?.storedSessionID else { return }
        Task { await store.setSessionArchived(id: storedID, archived: true) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(sendConversationMessage(_:)):
            return store.focusedSession != nil
                && !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case #selector(interruptConversation(_:)):
            return store.focusedSession?.isRunning == true
        case #selector(branchConversation(_:)):
            return store.focusedSession?.liveSessionID != nil
        case #selector(renameConversation(_:)), #selector(archiveConversation(_:)):
            return store.focusedSession?.storedSessionID != nil
        default:
            return true
        }
    }

    // MARK: - Utility

    private func promptForText(title: String, message: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Backdrop + empty state

/// Content pane background in Theme.bg.
private final class ChatBackgroundView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.bg.cgColor }
}

/// No focused conversation: centered avatar + prompt + accent "New
/// Conversation" button.
private final class ChatEmptyStateView: NSView {
    var onNewConversation: (() -> Void)?

    private let avatar = ChatAssistantAvatarView()
    private let titleLabel = NSTextField(labelWithString: "No conversation open")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let button = NSButton(title: "New Conversation", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = Theme.tx
        titleLabel.alignment = .center

        subtitleLabel.font = NSFont.systemFont(ofSize: 12.5)
        subtitleLabel.textColor = Theme.tx2
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.preferredMaxLayoutWidth = 380

        button.bezelStyle = .rounded
        button.keyEquivalent = "\r" // default-button accent fill
        button.target = self
        button.action = #selector(newConversationTapped)

        let column = NSStackView(views: [avatar, titleLabel, subtitleLabel, button])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 10
        column.setCustomSpacing(16, after: subtitleLabel)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])

        update(connectionState: .idle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(connectionState: HermesStore.ConnectionState) {
        switch connectionState {
        case .idle:
            subtitleLabel.stringValue = "Hermes is waking up."
            button.isEnabled = false
        case .launching:
            subtitleLabel.stringValue = "Starting the Hermes backend…"
            button.isEnabled = false
        case .connecting:
            subtitleLabel.stringValue = "Connecting to Hermes…"
            button.isEnabled = false
        case .ready:
            subtitleLabel.stringValue = "Start a new conversation, or pick one up from the sidebar."
            button.isEnabled = true
        case .failed(let message):
            subtitleLabel.stringValue = message
            button.isEnabled = false
        }
    }

    @objc private func newConversationTapped() {
        onNewConversation?()
    }
}
