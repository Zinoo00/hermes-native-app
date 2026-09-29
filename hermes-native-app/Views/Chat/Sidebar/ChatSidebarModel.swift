import Foundation

// Row model + grouping/pinning logic for the chat sidebar list.
// Pure data — no AppKit — so it stays trivially testable.

/// One flattened row of the sidebar table.
enum ChatSidebarRow {
    case header(String)
    case session(ChatSidebarEntry)
    /// Quiet full-width message row ("Starting Hermes…", empty states).
    case status(text: String, spinner: Bool)
}

/// Display model for one conversation row.
struct ChatSidebarEntry {
    let id: String
    var title: String
    var subtitle: String
    /// Monochrome platform monogram (design: T/D/S/§/W/@/> and › for native).
    var glyph: String
    var chipTooltip: String
    var pinned: Bool
}

/// Client-side pin list (the backend has no pin concept) kept in UserDefaults.
final class SessionPinStore {
    static let shared = SessionPinStore()

    private static let key = "hermes.pinnedSessions"
    private(set) var pinnedIDs: Set<String>

    private init() {
        pinnedIDs = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    func toggle(_ id: String) {
        if !pinnedIDs.insert(id).inserted {
            pinnedIDs.remove(id)
        }
        UserDefaults.standard.set(Array(pinnedIDs).sorted(), forKey: Self.key)
    }
}

enum ChatSidebarModel {

    static let groupLabels = ["Today", "Yesterday", "Previous 7 Days", "Older"]

    /// Date-grouped rows for the browse (non-search) list. Groups computed
    /// from `lastActive`; pinned rows sort first within their group.
    static func groupedRows(
        sessions: [SessionSummary],
        pinned: Set<String>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ChatSidebarRow] {
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let weekStart = calendar.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart

        var buckets: [[SessionSummary]] = [[], [], [], []]
        for session in sessions {
            let lastActive = Date(timeIntervalSince1970: session.lastActive)
            if lastActive >= todayStart {
                buckets[0].append(session)
            } else if lastActive >= yesterdayStart {
                buckets[1].append(session)
            } else if lastActive >= weekStart {
                buckets[2].append(session)
            } else {
                buckets[3].append(session)
            }
        }

        var rows: [ChatSidebarRow] = []
        for (index, bucket) in buckets.enumerated() where !bucket.isEmpty {
            rows.append(.header(groupLabels[index]))
            let sorted = bucket.sorted { a, b in
                let aPinned = pinned.contains(a.id)
                let bPinned = pinned.contains(b.id)
                if aPinned != bPinned { return aPinned }
                return a.lastActive > b.lastActive
            }
            rows.append(contentsOf: sorted.map { .session(entry(from: $0, pinned: pinned)) })
        }
        return rows
    }

    /// Rows for live REST search results (deduped by session id). Results for
    /// sessions already in the loaded list reuse that row's title/chip and
    /// show the matching snippet as the subtitle.
    static func searchRows(
        results: [SessionSearchResult],
        sessions: [SessionSummary],
        pinned: Set<String>
    ) -> [ChatSidebarRow] {
        var seen = Set<String>()
        var entries: [ChatSidebarEntry] = []
        for result in results {
            guard seen.insert(result.sessionID).inserted else { continue }
            let snippet = collapsed(result.snippet)
            if let summary = sessions.first(where: { $0.id == result.sessionID }) {
                var row = entry(from: summary, pinned: pinned)
                if !snippet.isEmpty { row.subtitle = snippet }
                entries.append(row)
            } else {
                entries.append(ChatSidebarEntry(
                    id: result.sessionID,
                    title: snippet.isEmpty ? "Conversation \(result.sessionID.prefix(8))" : snippet,
                    subtitle: result.model ?? sourceDisplayName(result.source) ?? "",
                    glyph: glyph(forSource: result.source),
                    chipTooltip: chipTooltip(forSource: result.source),
                    pinned: pinned.contains(result.sessionID)
                ))
            }
        }
        guard !entries.isEmpty else { return [] }
        return [.header("Results")] + entries.map { .session($0) }
    }

    static func entry(from session: SessionSummary, pinned: Set<String>) -> ChatSidebarEntry {
        let title = collapsed(session.title)
        let preview = collapsed(session.preview)
        let model = session.model ?? ""
        let displayTitle: String
        let subtitle: String
        if title.isEmpty {
            // Untitled: promote the preview so the row is still identifiable.
            displayTitle = preview.isEmpty ? "New conversation" : preview
            subtitle = model
        } else {
            displayTitle = title
            subtitle = preview.isEmpty ? model : preview
        }
        return ChatSidebarEntry(
            id: session.id,
            title: displayTitle,
            subtitle: subtitle,
            glyph: glyph(forSource: session.source),
            chipTooltip: chipTooltip(forSource: session.source),
            pinned: pinned.contains(session.id)
        )
    }

    // MARK: Platform monograms (design: monochrome, never brand colors)

    static func glyph(forSource source: String?) -> String {
        guard let source = source?.lowercased(), !source.isEmpty else { return "›" }
        if source.contains("telegram") { return "T" }
        if source.contains("discord") { return "D" }
        if source.contains("slack") { return "S" }
        if source.contains("signal") { return "§" }
        if source.contains("whatsapp") { return "W" }
        if source.contains("mail") { return "@" }
        if source.contains("cli") || source.contains("tui") || source.contains("terminal") { return ">" }
        return "›" // desktop / native / unknown
    }

    static func chipTooltip(forSource source: String?) -> String {
        if let name = sourceDisplayName(source), !isNativeSource(source) {
            return "From \(name)"
        }
        return "Native — this Mac"
    }

    static func sourceDisplayName(_ source: String?) -> String? {
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else { return nil }
        let lowered = source.lowercased()
        if lowered.contains("whatsapp") { return "WhatsApp" }
        if lowered.contains("cli") || lowered.contains("tui") { return "CLI" }
        if lowered.contains("mail") { return "Email" }
        return source.prefix(1).uppercased() + source.dropFirst()
    }

    private static func isNativeSource(_ source: String?) -> Bool {
        guard let source = source?.lowercased(), !source.isEmpty else { return true }
        return source.contains("desktop") || source.contains("native")
    }

    /// Single-line, whitespace-collapsed variant for row labels.
    static func collapsed(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
