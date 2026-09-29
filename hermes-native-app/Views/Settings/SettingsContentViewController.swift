import AppKit
import Combine

/// Settings content pane: per-category inset-grouped cards (design section 5).
/// Agent (behavior) · Compute (execution & sandbox, read-only v1) · Providers
/// (OAuth + API keys) · Appearance (theme + accent) · About.
final class SettingsContentViewController: NSViewController {

    private let store = AppEnvironment.shared.store
    private var cancellables = Set<AnyCancellable>()

    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let titleLabel = NSTextField.label("Settings", size: 20, weight: .semibold, color: Theme.tx)
    private let groupsStack = NSStackView()

    // Backend-loaded state (fetched once the connection is ready).
    private var config: ConfigPayload?
    private var oauthProviders: [ProviderOAuthInfo]?
    private var updateCheck: UpdateCheck?
    private var fetchedRemote = false

    override func loadView() {
        view = SettingsBackgroundView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        bind()
        render()
    }

    // MARK: UI skeleton

    private func buildUI() {
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        view.addSubview(scrollView)
        scrollView.pin(to: view)

        groupsStack.orientation = .vertical
        groupsStack.alignment = .leading
        groupsStack.spacing = 12

        let column = NSStackView(views: [titleLabel, groupsStack])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 22
        column.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(column)
        documentView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            column.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 28),
            column.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 36),
            column.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -36),
            column.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -70),
            groupsStack.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    private func bind() {
        SettingsSelectionState.shared.selection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)

        store.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state.isReady { self?.fetchRemoteIfNeeded() }
            }
            .store(in: &cancellables)

        store.$modelInfo
            .combineLatest(store.$modelOptions, store.$backendStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.render() }
            .store(in: &cancellables)
    }

    private func fetchRemoteIfNeeded() {
        guard !fetchedRemote, let rest = store.rest else { return }
        fetchedRemote = true
        Task {
            async let configResult = try? rest.config()
            async let providersResult = try? rest.oauthProviders()
            async let updateResult = try? rest.checkUpdate()
            self.config = await configResult
            self.oauthProviders = await providersResult
            self.updateCheck = await updateResult
            self.render()
        }
    }

    private func refetchProviders() {
        guard let rest = store.rest else { return }
        Task {
            self.oauthProviders = try? await rest.oauthProviders()
            await store.refreshModel()
            self.render()
        }
    }

    // MARK: Render

    private func render() {
        let category = SettingsSelectionState.shared.selection.value
        titleLabel.stringValue = category.title
        groupsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let groups: [(label: String?, rows: [SettingsRowConfig])]
        switch category {
        case .agent: groups = [("Behavior", agentRows())]
        case .compute: groups = [("Execution & sandbox", computeRows())]
        case .providers: groups = [("Model providers", providerRows())]
        case .appearance: groups = [(nil, appearanceRows())]
        case .about: groups = [("Hermes Desktop", aboutRows())]
        }

        for group in groups {
            if let label = group.label {
                let header = SectionLabelField(label)
                groupsStack.addArrangedSubview(header)
            }
            let card = SettingsGroupCard(rows: group.rows.map { SettingsRowView(config: $0) })
            groupsStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: groupsStack.widthAnchor).isActive = true
            groupsStack.setCustomSpacing(24, after: card)
        }
    }

    // MARK: Agent rows

    private func agentRows() -> [SettingsRowConfig] {
        let modelValue = store.modelInfo.map { info -> String in
            info.provider.isEmpty ? info.model : "\(info.model) · \(info.provider)"
        } ?? "—"

        let personality = store.focusedSession?.info?.personality
        let personalityValue = (personality?.isEmpty == false) ? personality!.capitalized : "SOUL.md"

        var learningValue = "On"
        if let config {
            if let enabled = config.values["memory"]["memory_enabled"].bool {
                learningValue = enabled ? "On" : "Off"
            }
        }

        return [
            SettingsRowConfig(
                title: "Default model",
                subtitle: "Used for new conversations",
                value: modelValue,
                action: { [weak self] in self?.showModelPicker() }
            ),
            SettingsRowConfig(
                title: "Personality",
                subtitle: "SOUL.md persona file",
                value: personalityValue,
                action: { [weak self] in self?.openSkillsTab("soul") }
            ),
            SettingsRowConfig(
                title: "Learning loop",
                subtitle: "Agent memory & self-created skills",
                value: learningValue,
                action: { [weak self] in self?.openSkillsTab("memory") }
            ),
            SettingsRowConfig(
                title: "Context files",
                subtitle: "AGENTS.md project context",
                value: "Open",
                action: { [weak self] in self?.openSkillsTab("agents") }
            ),
        ]
    }

    // MARK: Compute rows (read-only v1 — values from GET /api/config)

    private func computeRows() -> [SettingsRowConfig] {
        let backend = config?.values["terminal"]["backend"].string ?? "local"
        let backendValue = backend.prefix(1).uppercased() + backend.dropFirst()

        let maxChildren = config?.values["delegation"]["max_concurrent_children"].int ?? 3

        let yolo = config?.values["agent"]["yolo"].bool
            ?? config?.values["yolo"].bool
            ?? false
        let approvalValue = yolo ? "Off · full access" : "Approve · allowlist"

        let containerBackends: Set<String> = ["docker", "singularity", "modal", "daytona"]
        let isolationValue = containerBackends.contains(backend.lowercased())
            ? "On · \(backendValue)"
            : "Off"

        let editAction: () -> Void = { [weak self] in self?.showEditConfigAlert() }
        return [
            SettingsRowConfig(title: "Terminal backend",
                              subtitle: "Where tools execute",
                              value: backendValue, action: editAction),
            SettingsRowConfig(title: "Max parallel subagents",
                              subtitle: "Concurrent workstreams",
                              value: "\(maxChildren)", action: editAction),
            SettingsRowConfig(title: "Command approval",
                              subtitle: "Confirm risky shell commands",
                              value: approvalValue, action: editAction),
            SettingsRowConfig(title: "Container isolation",
                              subtitle: "Sandbox tool execution",
                              value: isolationValue, action: editAction),
        ]
    }

    // MARK: Provider rows

    private func providerRows() -> [SettingsRowConfig] {
        var rows: [SettingsRowConfig] = []

        if let providers = oauthProviders {
            for provider in providers {
                rows.append(SettingsRowConfig(
                    title: provider.name,
                    subtitle: providerSubtitle(provider),
                    value: providerStatus(provider),
                    action: { [weak self] in self?.providerClicked(provider) }
                ))
            }
        } else {
            rows.append(SettingsRowConfig(
                title: "Providers",
                subtitle: store.connectionState.isReady
                    ? "Loading provider status…"
                    : "Waiting for the Hermes backend…",
                value: ""
            ))
        }

        rows.append(SettingsRowConfig(
            title: "Add provider…",
            subtitle: "Set an API key for OpenRouter, OpenAI, a custom endpoint…",
            value: "",
            action: { [weak self] in self?.showAddProviderAlert() }
        ))
        return rows
    }

    private func providerSubtitle(_ provider: ProviderOAuthInfo) -> String {
        if let option = store.modelOptions?.providers.first(where: { $0.slug == provider.id }) {
            let count = option.totalModels ?? option.models.count
            if count > 0 { return "\(count) models" }
        }
        if provider.loggedIn, let source = provider.sourceLabel, !source.isEmpty {
            return source
        }
        switch provider.flow {
        case "pkce": return "OAuth sign-in"
        case "device_code": return "Device-code sign-in"
        case "external": return "External CLI sign-in"
        default: return "OAuth sign-in"
        }
    }

    private func providerStatus(_ provider: ProviderOAuthInfo) -> String {
        guard provider.loggedIn else { return "Not set" }
        let source = (provider.sourceLabel ?? "").lowercased()
        if source.contains("env") || source.contains("key") { return "Key set" }
        return "Connected"
    }

    private func providerClicked(_ provider: ProviderOAuthInfo) {
        if provider.loggedIn {
            showProviderDetails(provider)
        } else {
            startConnectFlow(provider)
        }
    }

    private func startConnectFlow(_ provider: ProviderOAuthInfo) {
        guard let rest = store.rest else { return }
        let sheet = ProviderConnectViewController(provider: provider, rest: rest) { [weak self] in
            self?.refetchProviders()
        }
        presentAsSheet(sheet)
    }

    private func showProviderDetails(_ provider: ProviderOAuthInfo) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = provider.name
        var lines: [String] = ["Status: \(providerStatus(provider))"]
        if let source = provider.sourceLabel, !source.isEmpty { lines.append("Source: \(source)") }
        if let preview = provider.tokenPreview, !preview.isEmpty { lines.append("Token: …\(preview)") }
        if let expires = provider.expiresAt, !expires.isEmpty { lines.append("Expires: \(expires)") }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Disconnect")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self, let rest = self.store.rest else { return }
            Task {
                do {
                    try await rest.oauthDisconnect(providerID: provider.id)
                } catch {
                    self.showSimpleAlert("Could not disconnect \(provider.name)",
                                         detail: error.localizedDescription, style: .warning)
                }
                self.refetchProviders()
            }
        }
    }

    private func showAddProviderAlert() {
        guard let window = view.window, let rest = store.rest else { return }
        let alert = NSAlert()
        alert.messageText = "Add provider"
        alert.informativeText = "Store an API key in the Hermes backend (~/.hermes/.env) and validate it."

        let keyField = NSTextField(frame: NSRect(x: 0, y: 34, width: 300, height: 24))
        keyField.placeholderString = "Env key — e.g. OPENROUTER_API_KEY"
        keyField.font = Theme.monoFont(ofSize: 11)
        let secretField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        secretField.placeholderString = "API key"

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 58))
        accessory.addSubview(keyField)
        accessory.addSubview(secretField)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = keyField

        alert.addButton(withTitle: "Save & Validate")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let key = keyField.stringValue.trimmingCharacters(in: .whitespaces).uppercased()
            let value = secretField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else { return }
            Task {
                do {
                    try await rest.setEnvVar(key: key, value: value)
                    let result = try await rest.validateProviderCredential(key: key, value: value)
                    let ok = result["ok"].bool ?? false
                    let reachable = result["reachable"].bool ?? false
                    let message = result["message"].string ?? ""
                    if ok {
                        self.showSimpleAlert("Key saved",
                                             detail: message.isEmpty ? "\(key) is set and validated." : message,
                                             style: .informational)
                    } else if reachable {
                        self.showSimpleAlert("Key saved, but validation failed",
                                             detail: message.isEmpty ? "The provider rejected this key." : message,
                                             style: .warning)
                    } else {
                        self.showSimpleAlert("Key saved (validation skipped)",
                                             detail: message.isEmpty ? "Could not reach the provider to verify the key." : message,
                                             style: .informational)
                    }
                } catch {
                    self.showSimpleAlert("Could not save the key", detail: error.localizedDescription, style: .warning)
                }
                self.refetchProviders()
            }
        }
    }

    // MARK: Appearance rows

    private func appearanceRows() -> [SettingsRowConfig] {
        let segmented = NSSegmentedControl(labels: ["Light", "Dark", "Auto"],
                                           trackingMode: .selectOne,
                                           target: self,
                                           action: #selector(appearanceSegmentChanged(_:)))
        switch Theme.shared.appearanceMode {
        case .light: segmented.selectedSegment = 0
        case .dark: segmented.selectedSegment = 1
        case .auto: segmented.selectedSegment = 2
        }

        return [
            SettingsRowConfig(title: "Theme",
                              subtitle: "Switch the whole window between light and dark",
                              accessory: segmented),
            SettingsRowConfig(title: "Accent color",
                              subtitle: "Tints selection, controls and highlights",
                              accessory: AccentSwatchesView()),
        ]
    }

    @objc private func appearanceSegmentChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: Theme.shared.appearanceMode = .light
        case 1: Theme.shared.appearanceMode = .dark
        default: Theme.shared.appearanceMode = .auto
        }
    }

    // MARK: About rows

    private func aboutRows() -> [SettingsRowConfig] {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let backendVersion = store.backendStatus?.version
        let versionValue = backendVersion.map { "\(appVersion) · backend \($0)" } ?? appVersion

        var channelValue = "—"
        if let check = updateCheck, !check.installMethod.isEmpty {
            channelValue = check.canApply ? "\(check.installMethod) · self-update" : check.installMethod
        }

        var updatesSubtitle = "Query the backend for a newer Hermes"
        if let check = updateCheck {
            updatesSubtitle = check.updateAvailable ? "Update available" : "Up to date"
        }

        return [
            SettingsRowConfig(title: "Version",
                              subtitle: "Hermes Desktop",
                              value: versionValue),
            SettingsRowConfig(title: "Release channel",
                              subtitle: "How Hermes installs updates",
                              value: channelValue),
            SettingsRowConfig(title: "Check for Updates…",
                              subtitle: updatesSubtitle,
                              value: "",
                              action: {
                                  NSApp.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: nil, from: nil)
                              }),
            SettingsRowConfig(title: "Documentation",
                              subtitle: "hermes-agent.nousresearch.com",
                              value: "Open",
                              action: {
                                  if let url = URL(string: "https://hermes-agent.nousresearch.com") {
                                      NSWorkspace.shared.open(url)
                                  }
                              }),
            SettingsRowConfig(title: "Built by",
                              subtitle: "Nous Research · MIT License",
                              value: "",
                              action: {
                                  if let url = URL(string: "https://nousresearch.com") {
                                      NSWorkspace.shared.open(url)
                                  }
                              }),
        ]
    }

    // MARK: Shared actions

    /// Navigate to Skills and (optimistically) tell the Skills hub which tab to
    /// open — cross-section contract via Notification only.
    private func openSkillsTab(_ tab: String) {
        NSApp.sendAction(#selector(AppDelegate.goToSkills(_:)), to: nil, from: nil)
        NotificationCenter.default.post(name: .hermesOpenSkillsTab,
                                        object: nil,
                                        userInfo: ["tab": tab])
    }

    private func showModelPicker() {
        guard let window = view.window else { return }
        guard let options = store.modelOptions, !options.providers.isEmpty,
              let rest = store.rest else {
            showSimpleAlert("Model options unavailable",
                            detail: "The model catalog has not loaded from the backend yet.",
                            style: .informational)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Default model"
        alert.informativeText = "Choose the model used for new conversations."

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        for provider in options.providers {
            for model in provider.models.prefix(40) {
                let item = NSMenuItem(title: "\(provider.name) · \(model)", action: nil, keyEquivalent: "")
                item.representedObject = [provider.slug, model]
                popup.menu?.addItem(item)
                if provider.isCurrent, model == options.currentModel {
                    popup.select(item)
                }
            }
        }
        guard popup.numberOfItems > 0 else {
            showSimpleAlert("No models available",
                            detail: "No provider reported selectable models.",
                            style: .informational)
            return
        }
        alert.accessoryView = popup

        alert.addButton(withTitle: "Set Model")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let pair = popup.selectedItem?.representedObject as? [String],
                  pair.count == 2 else { return }
            Task {
                do {
                    _ = try await rest.setModel(provider: pair[0], model: pair[1])
                } catch {
                    self.showSimpleAlert("Could not set the model",
                                         detail: error.localizedDescription, style: .warning)
                }
                await self.store.refreshModel()
                self.render()
            }
        }
    }

    private func showEditConfigAlert() {
        let path = store.backendStatus?.configPath ?? "~/.hermes/cli-config.yaml"
        let alert = NSAlert()
        alert.messageText = "Edit in config.yaml"
        alert.informativeText = "Compute settings are read-only here for now. Edit\n\(path)\nand restart the Hermes backend to change them."
        alert.addButton(withTitle: "OK")
        if store.backendStatus?.configPath != nil {
            alert.addButton(withTitle: "Reveal in Finder")
        }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func showSimpleAlert(_ message: String, detail: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = detail
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - Helper views

private final class SettingsBackgroundView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.bg.cgColor
    }
}
