//
//  DashboardModel.swift
//  hermes-native-app
//
//  Shared state for the Dashboard (Overview) section. Synthesizes calendar
//  events from REAL backend data — store.sessions (recent activity) and
//  store.cronJobs (run history / next runs) — owns the sidebar multi-select
//  filters, and exposes day navigation over days that actually have data.
//  DashboardSidebarViewController and DashboardContentViewController are
//  constructed independently by SectionCoordinator, so they meet here.
//

import AppKit
import Combine

// MARK: - Filter lenses

/// STATUS group — outcome lenses.
enum DashboardStatusLens: String, CaseIterable {
    case flagged, awaiting, done

    var title: String {
        switch self {
        case .flagged: return "Flagged"
        case .awaiting: return "Awaiting"
        case .done: return "Done"
        }
    }

    var symbolName: String {
        switch self {
        case .flagged: return "exclamationmark.triangle"
        case .awaiting: return "hourglass"
        case .done: return "checkmark.circle"
        }
    }
}

/// ACTIVITY group — event taxonomy lenses.
enum DashboardActivityLens: String, CaseIterable {
    case messages, automations, subagents, learning

    var title: String {
        switch self {
        case .messages: return "Messages"
        case .automations: return "Automations"
        case .subagents: return "Subagents"
        case .learning: return "Learning"
        }
    }

    var symbolName: String {
        switch self {
        case .messages: return "bubble.left"
        case .automations: return "clock"
        case .subagents: return "point.3.connected.trianglepath.dotted"
        case .learning: return "sparkles"
        }
    }
}

/// PLATFORM group row, built from distinct session sources.
struct DashboardPlatform: Identifiable, Hashable {
    let key: String
    let name: String
    let glyph: String

    var id: String { key }

    static func display(for key: String) -> (name: String, glyph: String) {
        switch key {
        case "telegram": return ("Telegram", "T")
        case "discord": return ("Discord", "D")
        case "slack": return ("Slack", "S")
        case "signal": return ("Signal", "§")
        case "whatsapp": return ("WhatsApp", "W")
        case "email", "mail": return ("Email", "@")
        case "cli", "terminal", "tui": return ("CLI", ">")
        case "native", "desktop", "app": return ("Native", "›")
        case "web": return ("Web", "W")
        default:
            let name = key.prefix(1).uppercased() + key.dropFirst()
            return (name, key.prefix(1).uppercased())
        }
    }
}

// MARK: - Synthesized activity event

/// One entry of the ACTIVITY day calendar, synthesized from real data.
struct DashboardEvent: Identifiable {
    enum Outcome {
        case ok        // done — green checks, Done lens
        case flagged   // error — red, Flagged lens
        case awaiting  // running / awaiting — accent, Awaiting lens
        case neutral   // scheduled etc. — no lens
    }

    let id: String
    let date: Date
    /// Cron runs / scheduled runs render in the "all-day" row.
    let isAllDay: Bool
    let title: String
    /// Normalized platform key ("telegram") or nil when unknown.
    let sourceKey: String?
    /// Display name for the platform/source tag.
    let sourceName: String?
    let outcome: Outcome
    let activity: DashboardActivityLens
    /// Stored session id — click navigates to the conversation.
    let sessionID: String?

    var timeLabel: String { DashboardFormat.time.string(from: date) }
}

/// Sidebar badge counts, computed from real data.
struct DashboardCounts {
    var flagged = 0
    var awaiting = 0
    var done = 0
    var messages = 0
    var automations = 0
    var subagents = 0
    var learning = 0
    var platformCounts: [String: Int] = [:]
}

// MARK: - Model

final class DashboardModel: ObservableObject {
    static let shared = DashboardModel(store: AppEnvironment.shared.store)

    let store: HermesStore
    private var cancellables = Set<AnyCancellable>()

    /// All synthesized events, newest first (every day, unfiltered).
    @Published private(set) var events: [DashboardEvent] = []

    // Multi-select filters. Empty selection = show all; AND across groups,
    // OR within a group.
    @Published var selectedStatuses: Set<DashboardStatusLens> = []
    @Published var selectedActivities: Set<DashboardActivityLens> = []
    @Published var selectedPlatforms: Set<String> = []

    /// Start-of-day for the calendar day view (defaults to today).
    @Published var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    private init(store: HermesStore) {
        self.store = store
        store.$sessions
            .combineLatest(store.$cronJobs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions, jobs in
                self?.rebuildEvents(sessions: sessions, cronJobs: jobs)
            }
            .store(in: &cancellables)
    }

    // MARK: Event synthesis (real data only)

    private func rebuildEvents(sessions: [SessionSummary], cronJobs: [CronJob]) {
        var out: [DashboardEvent] = []

        for session in sessions {
            let ts = session.lastActive > 0 ? session.lastActive : session.startedAt
            guard ts > 0 else { continue }
            var title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { title = session.preview.trimmingCharacters(in: .whitespacesAndNewlines) }
            if title.isEmpty { title = "Untitled conversation" }
            let key = Self.normalizedSource(session.source)
            out.append(DashboardEvent(
                id: "session-\(session.id)",
                date: Date(timeIntervalSince1970: ts),
                isAllDay: false,
                title: title,
                sourceKey: key,
                sourceName: key.map { DashboardPlatform.display(for: $0).name },
                outcome: session.isActive ? .awaiting : .ok,
                activity: session.parentSessionID != nil ? .subagents : .messages,
                sessionID: session.id
            ))
        }

        for job in cronJobs {
            let name = job.name.isEmpty ? "Scheduled job" : job.name
            let key = Self.normalizedSource(job.deliver)
            let sourceName = key.map { DashboardPlatform.display(for: $0).name }
            if let last = Self.parseDate(job.lastRunAt) {
                let failed = Self.isErrorStatus(job.lastStatus)
                    || (job.lastError?.isEmpty == false)
                out.append(DashboardEvent(
                    id: "cron-last-\(job.id)",
                    date: last,
                    isAllDay: true,
                    title: "\(name) ran",
                    sourceKey: key,
                    sourceName: sourceName,
                    outcome: failed ? .flagged : .ok,
                    activity: .automations,
                    sessionID: nil
                ))
            }
            if let next = Self.parseDate(job.nextRunAt), job.enabled {
                out.append(DashboardEvent(
                    id: "cron-next-\(job.id)",
                    date: next,
                    isAllDay: true,
                    title: "\(name) scheduled",
                    sourceKey: key,
                    sourceName: sourceName,
                    outcome: .neutral,
                    activity: .automations,
                    sessionID: nil
                ))
            }
        }

        events = out.sorted { $0.date > $1.date }
    }

    private static func normalizedSource(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        return raw
    }

    private static func isErrorStatus(_ status: String?) -> Bool {
        guard let status = status?.lowercased() else { return false }
        return status.contains("error") || status.contains("fail")
            || status.contains("flag") || status.contains("warn")
    }

    // MARK: Filters

    var hasActiveFilters: Bool {
        !selectedStatuses.isEmpty || !selectedActivities.isEmpty || !selectedPlatforms.isEmpty
    }

    func toggleStatus(_ lens: DashboardStatusLens) {
        if selectedStatuses.contains(lens) { selectedStatuses.remove(lens) }
        else { selectedStatuses.insert(lens) }
    }

    func toggleActivity(_ lens: DashboardActivityLens) {
        if selectedActivities.contains(lens) { selectedActivities.remove(lens) }
        else { selectedActivities.insert(lens) }
    }

    func togglePlatform(_ key: String) {
        if selectedPlatforms.contains(key) { selectedPlatforms.remove(key) }
        else { selectedPlatforms.insert(key) }
    }

    /// AND across groups, OR within a group; empty group = pass.
    func matchesFilters(_ event: DashboardEvent) -> Bool {
        if !selectedPlatforms.isEmpty {
            guard let key = event.sourceKey, selectedPlatforms.contains(key) else { return false }
        }
        if !selectedStatuses.isEmpty {
            let hit = (selectedStatuses.contains(.flagged) && event.outcome == .flagged)
                || (selectedStatuses.contains(.awaiting) && event.outcome == .awaiting)
                || (selectedStatuses.contains(.done) && event.outcome == .ok)
            if !hit { return false }
        }
        if !selectedActivities.isEmpty, !selectedActivities.contains(event.activity) {
            return false
        }
        return true
    }

    func filteredEvents(on day: Date) -> [DashboardEvent] {
        let calendar = Calendar.current
        return events.filter { calendar.isDate($0.date, inSameDayAs: day) && matchesFilters($0) }
    }

    /// Attention items are blocking (awaiting) conversation interactions.
    /// Platform is only resolvable for the focused session; unknown platforms
    /// stay visible so actionable approvals are never hidden by accident.
    func isAttentionVisible(_ item: AttentionItem) -> Bool {
        if !selectedStatuses.isEmpty, !selectedStatuses.contains(.awaiting) { return false }
        if !selectedActivities.isEmpty, !selectedActivities.contains(.messages) { return false }
        if !selectedPlatforms.isEmpty,
           let source = sessionSummary(for: item)?.source,
           let key = Self.normalizedSource(source),
           !selectedPlatforms.contains(key) {
            return false
        }
        return true
    }

    // MARK: Counts (real data)

    var counts: DashboardCounts {
        var c = DashboardCounts()
        for event in events {
            switch event.outcome {
            case .flagged: c.flagged += 1
            case .awaiting: c.awaiting += 1
            case .ok: c.done += 1
            case .neutral: break
            }
            switch event.activity {
            case .messages: c.messages += 1
            case .automations: c.automations += 1
            case .subagents: c.subagents += 1
            case .learning: c.learning += 1
            }
            if let key = event.sourceKey {
                c.platformCounts[key, default: 0] += 1
            }
        }
        // Pending attention items are awaiting interactions too.
        c.awaiting += store.attentionItems.count
        return c
    }

    /// Distinct platforms across session sources, largest first.
    var platforms: [DashboardPlatform] {
        var keys: [String] = []
        for session in store.sessions {
            if let key = Self.normalizedSource(session.source), !keys.contains(key) {
                keys.append(key)
            }
        }
        let platformCounts = counts.platformCounts
        return keys
            .map { key -> DashboardPlatform in
                let display = DashboardPlatform.display(for: key)
                return DashboardPlatform(key: key, name: display.name, glyph: display.glyph)
            }
            .sorted {
                let a = platformCounts[$0.key] ?? 0
                let b = platformCounts[$1.key] ?? 0
                return a == b ? $0.name < $1.name : a > b
            }
    }

    // MARK: Attention helpers

    /// Live gateway session id -> stored SessionSummary (only resolvable when
    /// the item belongs to the focused conversation).
    func sessionSummary(for item: AttentionItem) -> SessionSummary? {
        guard let focused = store.focusedSession else { return nil }
        guard item.sessionID == nil || item.sessionID == focused.liveSessionID else { return nil }
        guard let storedID = focused.storedSessionID else { return nil }
        return store.sessions.first { $0.id == storedID }
    }

    func sessionName(for item: AttentionItem) -> String? {
        guard let focused = store.focusedSession else { return nil }
        if item.sessionID == nil || item.sessionID == focused.liveSessionID {
            if let title = focused.title, !title.isEmpty { return title }
            if let summary = sessionSummary(for: item), !summary.title.isEmpty {
                return summary.title
            }
        }
        return nil
    }

    // MARK: Day navigation (steps days that have data)

    /// Start-of-day for every day with at least one event, plus today; ascending.
    var daysWithData: [Date] {
        let calendar = Calendar.current
        var days = Set(events.map { calendar.startOfDay(for: $0.date) })
        days.insert(calendar.startOfDay(for: Date()))
        return days.sorted()
    }

    var previousDay: Date? {
        daysWithData.last { $0 < selectedDay }
    }

    var nextDay: Date? {
        daysWithData.first { $0 > selectedDay }
    }

    func stepDay(forward: Bool) {
        if forward, let next = nextDay { selectedDay = next }
        if !forward, let previous = previousDay { selectedDay = previous }
    }
}

// MARK: - Shared formatting

enum DashboardFormat {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()

    /// "Wed, Jul 2" — content header date.
    static let headerDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, MMM d"
        return f
    }()

    /// "Jun 30" — day-nav label for days beyond yesterday.
    static let navDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    /// "July 2," — big calendar date (year rendered separately, muted).
    static let bigDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM d,"
        return f
    }()

    static let year: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy"
        return f
    }()

    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE"
        return f
    }()

    static func timeAgo(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return navDay.string(from: date)
    }

    /// Hour-rail gutter label parts ("7" + "PM", "Noon" + "").
    static func hourLabel(_ hour: Int) -> (main: String, suffix: String) {
        if hour == 12 { return ("Noon", "") }
        let h = hour % 12 == 0 ? 12 : hour % 12
        return ("\(h)", hour < 12 ? "AM" : "PM")
    }
}

// MARK: - Cron date parsing

extension DashboardModel {
    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso = ISO8601DateFormatter()

    private static let bareDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private static let spacedDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let date = isoWithFraction.date(from: raw) { return date }
        if let date = iso.date(from: raw) { return date }
        if let date = bareDateTime.date(from: raw) { return date }
        if let date = spacedDateTime.date(from: raw) { return date }
        if let epoch = Double(raw), epoch > 0 { return Date(timeIntervalSince1970: epoch) }
        return nil
    }
}

// MARK: - Dashboard-only semantic washes

enum DashboardColors {
    /// Soft red wash behind red counts / flag icon chips.
    static let dangerSoft = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(hex: 0xFF6058, alpha: 0.14)
            : NSColor(hex: 0xFF3B30, alpha: 0.12)
    }

    /// Soft green wash behind ok counts / the all-caught-up check circle.
    static let okSoft = NSColor(hex: 0x7FC69A, alpha: 0.16)

    /// Neutral 3px event bar (design uses --tx2 for neutral events).
    static var neutralBar: NSColor { Theme.tx2 }
}
