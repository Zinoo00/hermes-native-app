import AppKit

/// Small progress sheet that drives a provider OAuth flow:
///   POST /api/providers/oauth/{id}/start → open auth_url in the browser →
///   pkce: paste-code field + submit; device_code/loopback: poll until approved.
final class ProviderConnectViewController: NSViewController {

    private let provider: ProviderOAuthInfo
    private let rest: RestClient
    private let onFinished: () -> Void

    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let codeRow = NSStackView()
    private let codeField = NSTextField()
    private let submitButton = NSButton(title: "Submit Code", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    private var startInfo: OAuthStartInfo?
    private var flowTask: Task<Void, Never>?
    private var succeeded = false

    init(provider: ProviderOAuthInfo, rest: RestClient, onFinished: @escaping () -> Void) {
        self.provider = provider
        self.rest = rest
        self.onFinished = onFinished
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let view = NSView()

        let title = NSTextField.label("Connect \(provider.name)", size: 15, weight: .semibold, color: Theme.tx)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        statusLabel.font = Theme.bodyFont
        statusLabel.textColor = Theme.tx2
        statusLabel.stringValue = "Contacting the Hermes backend…"

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .firstBaseline
        statusRow.spacing = 8

        codeField.placeholderString = "Paste the code from your browser"
        codeField.font = Theme.monoFont(ofSize: 12)
        codeField.translatesAutoresizingMaskIntoConstraints = false
        codeField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        submitButton.target = self
        submitButton.action = #selector(submitCode(_:))
        submitButton.bezelStyle = .rounded
        submitButton.keyEquivalent = "\r"

        codeRow.orientation = .horizontal
        codeRow.spacing = 8
        codeRow.addArrangedSubview(codeField)
        codeRow.addArrangedSubview(submitButton)
        codeRow.isHidden = true

        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [NSView(), cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let column = NSStackView(views: [title, statusRow, codeRow, buttonRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 420),
            column.topAnchor.constraint(equalTo: view.topAnchor),
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusRow.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
            buttonRow.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
        ])
        self.view = view
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard flowTask == nil else { return }
        spinner.startAnimation(nil)
        flowTask = Task { await runFlow() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        flowTask?.cancel()
        if succeeded { onFinished() }
    }

    // MARK: Flow

    private func runFlow() async {
        let info: OAuthStartInfo
        do {
            info = try await rest.oauthStart(providerID: provider.id)
        } catch {
            fail("Could not start the sign-in flow: \(error.localizedDescription)")
            return
        }
        startInfo = info

        if let auth = info.authURL, let url = URL(string: auth) {
            NSWorkspace.shared.open(url)
        } else if let verification = info.verificationURL, let url = URL(string: verification) {
            NSWorkspace.shared.open(url)
        }

        if info.flow == "pkce" {
            spinner.stopAnimation(nil)
            statusLabel.stringValue =
                "A browser window opened. Approve access, then paste the code you receive below."
            codeRow.isHidden = false
            view.window?.makeFirstResponder(codeField)
            return
        }

        if let code = info.userCode, !code.isEmpty {
            statusLabel.stringValue =
                "Enter code \(code) in the browser window, then approve access. Waiting for approval…"
        } else {
            statusLabel.stringValue = "Approve access in the browser window. Waiting for approval…"
        }
        await poll(sessionID: info.sessionID, interval: info.pollInterval ?? 3)
    }

    private func poll(sessionID: String, interval: Int) async {
        let delay = UInt64(max(2, interval)) * 1_000_000_000
        while !Task.isCancelled {
            do {
                let result = try await rest.oauthPoll(providerID: provider.id, sessionID: sessionID)
                switch result.status {
                case "approved":
                    finishConnected()
                    return
                case "denied", "expired", "error":
                    fail(result.errorMessage ?? "Sign-in \(result.status).")
                    return
                default:
                    break // pending — keep waiting
                }
            } catch {
                // Transient poll failure: keep trying until cancelled.
            }
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    @objc private func submitCode(_ sender: Any?) {
        guard let info = startInfo else { return }
        let code = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        submitButton.isEnabled = false
        spinner.startAnimation(nil)
        statusLabel.stringValue = "Verifying code…"
        Task {
            do {
                _ = try await rest.oauthSubmit(providerID: provider.id,
                                               sessionID: info.sessionID,
                                               code: code)
                finishConnected()
            } catch {
                submitButton.isEnabled = true
                fail("The code was not accepted: \(error.localizedDescription)")
            }
        }
    }

    private func finishConnected() {
        succeeded = true
        spinner.stopAnimation(nil)
        codeRow.isHidden = true
        statusLabel.textColor = Theme.ok
        statusLabel.stringValue = "Connected ✓"
        cancelButton.title = "Done"
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if self.presentingViewController != nil { self.dismiss(self) }
        }
    }

    private func fail(_ message: String) {
        spinner.stopAnimation(nil)
        statusLabel.textColor = Theme.danger
        statusLabel.stringValue = message
        cancelButton.title = "Close"
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss(self)
    }
}
