import Foundation

/// Process-wide dependency container. View controllers resolve the backend
/// store through `AppEnvironment.shared.store` instead of threading it through
/// initializers (section VCs are constructed by SectionCoordinator's factory).
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let store = HermesStore()

    private init() {}
}
