import AppKit
import Combine

/// Chat sidebar (design §1): NSSearchField over a date-grouped source list of
/// stored conversations (TODAY / YESTERDAY / PREVIOUS 7 DAYS / OLDER), with
/// the shared usage/status footer pinned to the bottom.
///
/// Data: `HermesStore.sessions` for browsing; `GET /api/sessions/search`
/// (debounced 250 ms) while a query is active. Row selection resumes the
/// stored conversation via `store.selectSession(storedID:)` and mirrors
/// `store.$focusedSession`.
final class ChatSidebarViewController: NSViewController,
                                       NSTableViewDataSource,
                                       NSTableViewDelegate,
                                       NSMenuDelegate {

    private let store = AppEnvironment.shared.store
    private var cancellables = Set<AnyCancellable>()

    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private lazy var footer = SidebarFooterView(store: store)

    private var rows: [ChatSidebarRow] = []
    /// nil = browsing store.sessions; non-nil = live REST search results.
    private var searchResults: [SessionSearchResult]?
    private var searchDebounce: DispatchWorkItem?
    private var searchTask: Task<Void, Never>?
    private var suppressSelectionCallback = false

    private enum CellID {
        static let session = NSUserInterfaceItemIdentifier("ChatSidebarSessionCell")
        static let header = NSUserInterfaceItemIdentifier("ChatSidebarHeaderCell")
        static let status = NSUserInterfaceItemIdentifier("ChatSidebarStatusCell")
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - View construction

    override func loadView() {
        view = NSView()

        // Search (design: 28pt field, "Search" placeholder, 10/12/8 padding).
        searchField.placeholderString = "Search"
        searchField.font = Theme.bodyFont
        searchField.focusRingType = .default
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchField)

        // Source list, transparent over the sidebar vibrancy.
        tableView.style = .sourceList
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.rowHeight = ChatSidebarMetrics.sessionRowHeight
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let contextMenu = NSMenu()
        contextMenu.delegate = self
        tableView.menu = contextMenu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        view.addSubview(footer)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bind()
        rebuildRows()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Pick up conversations created elsewhere since the last look.
        if store.connectionState.isReady {
            Task { await store.refreshSessions() }
        }
    }

    // MARK: - Store binding

    private func bind() {
        store.$sessions
            .combineLatest(store.$connectionState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.rebuildRows()
            }
            .store(in: &cancellables)

        store.$focusedSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                self?.reflectSelection(storedID: session?.storedSessionID)
            }
            .store(in: &cancellables)

        // Selection capsule + pin glyphs are accent-tinted custom draws;
        // rebuild so every visible row re-resolves Theme.acc.
        Theme.shared.onAccentChange(storeIn: &cancellables) { [weak self] in
            self?.rebuildRows()
        }
    }

    // MARK: - Row assembly

    private func rebuildRows() {
        if !store.connectionState.isReady {
            let failed: Bool
            if case .failed = store.connectionState { failed = true } else { failed = false }
            rows = [.status(
                text: failed ? "Hermes is offline" : "Starting Hermes…",
                spinner: !failed
            )]
        } else if let results = searchResults {
            let built = ChatSidebarModel.searchRows(
                results: results,
                sessions: store.sessions,
                pinned: SessionPinStore.shared.pinnedIDs
            )
            rows = built.isEmpty ? [.status(text: "No conversations match.", spinner: false)] : built
        } else if store.sessions.isEmpty {
            rows = [.status(text: "No conversations yet", spinner: false)]
        } else {
            rows = ChatSidebarModel.groupedRows(
                sessions: store.sessions,
                pinned: SessionPinStore.shared.pinnedIDs
            )
        }
        tableView.reloadData()
        reflectSelection(storedID: store.focusedSession?.storedSessionID)
    }

    private func rowIndex(forSessionID id: String) -> Int? {
        rows.firstIndex { row in
            if case .session(let entry) = row { return entry.id == id }
            return false
        }
    }

    private func sessionEntry(atRow index: Int) -> ChatSidebarEntry? {
        guard rows.indices.contains(index), case .session(let entry) = rows[index] else { return nil }
        return entry
    }

    private func reflectSelection(storedID: String?) {
        suppressSelectionCallback = true
        defer { suppressSelectionCallback = false }
        if let storedID, let index = rowIndex(forSessionID: storedID) {
            let alreadySelected = tableView.selectedRow == index
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            if !alreadySelected {
                tableView.scrollRowToVisible(index)
            }
        } else {
            tableView.deselectAll(nil)
        }
    }

    // MARK: - Search (debounced 250 ms -> GET /api/sessions/search)

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchDebounce?.cancel()
        let query = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            searchTask?.cancel()
            searchTask = nil
            if searchResults != nil {
                searchResults = nil
                rebuildRows()
            }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.performSearch(query)
        }
        searchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func performSearch(_ query: String) {
        guard let rest = store.rest else { return }
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do {
                let results = try await rest.searchSessions(query: query)
                guard let self, !Task.isCancelled else { return }
                // Drop stale responses after further typing.
                guard self.currentQuery == query else { return }
                self.searchResults = results
                self.rebuildRows()
            } catch {
                guard let self, !Task.isCancelled else { return }
                guard self.currentQuery == query else { return }
                self.searchResults = []
                self.rebuildRows()
            }
        }
    }

    private var currentQuery: String {
        searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return ChatSidebarMetrics.headerRowHeight
        case .session: return ChatSidebarMetrics.sessionRowHeight
        case .status: return ChatSidebarMetrics.statusRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        false // headers are plain rows styled by SectionLabelField
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .session = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard case .session = rows[row] else { return nil }
        return ChatSidebarRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = tableView.makeView(withIdentifier: CellID.header, owner: nil)
                as? ChatSidebarHeaderCellView ?? {
                    let view = ChatSidebarHeaderCellView()
                    view.identifier = CellID.header
                    return view
                }()
            cell.configure(title: title)
            return cell

        case .session(let entry):
            let cell = tableView.makeView(withIdentifier: CellID.session, owner: nil)
                as? ConversationCellView ?? {
                    let view = ConversationCellView()
                    view.identifier = CellID.session
                    return view
                }()
            cell.configure(with: entry)
            return cell

        case .status(let text, let spinner):
            let cell = tableView.makeView(withIdentifier: CellID.status, owner: nil)
                as? ChatSidebarStatusCellView ?? {
                    let view = ChatSidebarStatusCellView()
                    view.identifier = CellID.status
                    return view
                }()
            cell.configure(text: text, spinner: spinner)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallback else { return }
        let selected = tableView.selectedRow
        guard selected >= 0, let entry = sessionEntry(atRow: selected) else { return }
        guard entry.id != store.focusedSession?.storedSessionID else { return }
        Task {
            await store.selectSession(storedID: entry.id)
            // On failure focusedSession is unchanged; snap the highlight back.
            reflectSelection(storedID: store.focusedSession?.storedSessionID)
        }
    }

    // MARK: - Context menu (pin / rename / archive / delete)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard menu === tableView.menu,
              let entry = sessionEntry(atRow: tableView.clickedRow) else { return }

        let pin = NSMenuItem(
            title: entry.pinned ? "Unpin" : "Pin",
            action: #selector(pinRow(_:)),
            keyEquivalent: ""
        )
        pin.target = self
        pin.representedObject = entry
        menu.addItem(pin)

        let rename = NSMenuItem(title: "Rename…", action: #selector(renameRow(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = entry
        menu.addItem(rename)

        let archive = NSMenuItem(title: "Archive", action: #selector(archiveRow(_:)), keyEquivalent: "")
        archive.target = self
        archive.representedObject = entry
        menu.addItem(archive)

        menu.addItem(.separator())

        let delete = NSMenuItem(title: "Delete", action: #selector(deleteRow(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = entry
        menu.addItem(delete)
    }

    @objc private func pinRow(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ChatSidebarEntry else { return }
        SessionPinStore.shared.toggle(entry.id)
        rebuildRows()
    }

    @objc private func renameRow(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ChatSidebarEntry else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Conversation"
        alert.informativeText = "Enter a new title for this conversation."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 230, height: 24))
        field.stringValue = entry.title
        field.font = Theme.bodyFont
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        runAlert(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != entry.title else { return }
            Task { await self.store.renameSession(id: entry.id, title: title) }
        }
    }

    @objc private func archiveRow(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ChatSidebarEntry else { return }
        Task { await store.setSessionArchived(id: entry.id, archived: true) }
    }

    @objc private func deleteRow(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ChatSidebarEntry else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this conversation?"
        alert.informativeText = "“\(entry.title)” and its messages will be permanently deleted."
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        runAlert(alert) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { await self.store.deleteSession(id: entry.id) }
        }
    }

    private func runAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
