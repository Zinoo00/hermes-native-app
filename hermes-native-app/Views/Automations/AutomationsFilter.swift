import Foundation
import Combine

/// Sidebar filter for the Automations section (design: SCHEDULES — All / Active / Paused).
enum AutomationsFilter: String, CaseIterable {
    case all, active, paused

    var title: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .paused: return "Paused"
        }
    }

    func matches(_ job: CronJob) -> Bool {
        switch self {
        case .all: return true
        case .active: return job.enabled
        case .paused: return !job.enabled
        }
    }
}

/// Sidebar and content view controllers are separate instances built by
/// SectionCoordinator; this tiny shared state links the sidebar's single-select
/// filter to the content list.
@MainActor
final class AutomationsFilterState {
    static let shared = AutomationsFilterState()
    let selection = CurrentValueSubject<AutomationsFilter, Never>(.all)
    private init() {}
}
