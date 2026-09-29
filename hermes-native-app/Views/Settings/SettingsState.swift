import Foundation
import Combine

/// Settings sidebar categories (design: Agent / Compute / Providers /
/// Appearance / About, each with a small glyph tile).
enum SettingsCategory: String, CaseIterable {
    case agent, compute, providers, appearance, about

    var title: String {
        switch self {
        case .agent: return "Agent"
        case .compute: return "Compute"
        case .providers: return "Providers"
        case .appearance: return "Appearance"
        case .about: return "About"
        }
    }

    /// Tile glyphs straight from the design (☤ ▦ ◈ ◐ i).
    var glyph: String {
        switch self {
        case .agent: return "\u{2624}"
        case .compute: return "\u{25A6}"
        case .providers: return "\u{25C8}"
        case .appearance: return "\u{25D0}"
        case .about: return "i"
        }
    }
}

/// Links the Settings sidebar selection to the content pane (separate view
/// controllers built by SectionCoordinator).
@MainActor
final class SettingsSelectionState {
    static let shared = SettingsSelectionState()
    let selection = CurrentValueSubject<SettingsCategory, Never>(.agent)
    private init() {}
}

extension Notification.Name {
    /// Cross-section contract with the Skills hub: posted (optimistically)
    /// right after navigating to .skills, with userInfo ["tab": <String>] where
    /// tab ∈ "soul" | "agents" | "memory" | "skills" | "commands" | …
    /// The Skills view controllers observe this and switch tabs.
    static let hermesOpenSkillsTab = Notification.Name("hermes.openSkillsTab")
}
