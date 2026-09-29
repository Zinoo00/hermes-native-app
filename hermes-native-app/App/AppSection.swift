import Foundation

enum AppSection: String, CaseIterable {
    case chat
    case skills
    case automations
    case dashboard
    case settings

    var title: String {
        switch self {
        case .chat: return "Chat"
        case .skills: return "Skills"
        case .automations: return "Automations"
        case .dashboard: return "Dashboard"
        case .settings: return "Settings"
        }
    }

    /// Index in the toolbar segmented control; nil = no segment selected.
    var segmentIndex: Int? {
        switch self {
        case .chat: return 0
        case .skills: return 1
        case .automations: return 2
        case .dashboard, .settings: return nil
        }
    }

    static func forSegment(_ index: Int) -> AppSection? {
        switch index {
        case 0: return .chat
        case 1: return .skills
        case 2: return .automations
        default: return nil
        }
    }

    /// Workspace sections participate in the Dashboard-grid toggle round trip.
    var isWorkspace: Bool {
        switch self {
        case .chat, .skills, .automations: return true
        case .dashboard, .settings: return false
        }
    }
}
