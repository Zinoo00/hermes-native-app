import AppKit
import Combine

// Design tokens transcribed from docs/design/hermes-appkit.html (LIGHT / DARK maps).

enum AppearanceMode: String, CaseIterable {
    case light, dark, auto
}

enum AccentChoice: String, CaseIterable {
    case blue, purple, pink, orange, green, graphite

    var displayName: String { rawValue.capitalized }

    var lightHex: UInt32 {
        switch self {
        case .blue: return 0x007AFF
        case .purple: return 0xAF52DE
        case .pink: return 0xFF2D55
        case .orange: return 0xFF9500
        case .green: return 0x28CD41
        case .graphite: return 0x8E8E93
        }
    }

    var darkHex: UInt32 {
        switch self {
        case .blue: return 0x0A84FF
        case .purple: return 0xBF5AF2
        case .pink: return 0xFF375F
        case .orange: return 0xFF9F0A
        case .green: return 0x30D158
        case .graphite: return 0x98989D
        }
    }
}

@MainActor
final class Theme {
    static let shared = Theme()

    nonisolated private static let accentKey = "hermes.accentChoice"
    nonisolated private static let appearanceKey = "hermes.appearanceMode"

    // Mirrored outside the actor so NSColor dynamic providers (resolved at draw
    // time, appearance-dependent) can read it without isolation hops.
    nonisolated(unsafe) private static var accentValue: AccentChoice =
        AccentChoice(rawValue: UserDefaults.standard.string(forKey: Theme.accentKey) ?? "") ?? .blue

    private let accentSubject: CurrentValueSubject<AccentChoice, Never>

    /// Fires when the user picks a different accent; custom views re-tint on
    /// this. Stock controls keep the asset-catalog accent on purpose.
    var accentPublisher: AnyPublisher<AccentChoice, Never> {
        accentSubject.eraseToAnyPublisher()
    }

    var accent: AccentChoice {
        get { accentSubject.value }
        set {
            guard newValue != accentSubject.value else { return }
            Theme.accentValue = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: Theme.accentKey)
            accentSubject.send(newValue)
        }
    }

    var appearanceMode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Theme.appearanceKey)
            applyAppearance()
        }
    }

    private init() {
        accentSubject = CurrentValueSubject(Theme.accentValue)
        appearanceMode = AppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: Theme.appearanceKey) ?? ""
        ) ?? .auto
    }

    /// Runs `body` on the main queue whenever the accent changes, storing the
    /// subscription in `set`. Collapses the repeated accentPublisher wiring.
    func onAccentChange(storeIn set: inout Set<AnyCancellable>, _ body: @escaping () -> Void) {
        accentPublisher
            .receive(on: DispatchQueue.main)
            .sink { _ in body() }
            .store(in: &set)
    }

    func applyAppearance() {
        switch appearanceMode {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Colors (dynamic, resolve per effective appearance)

    static let bg = dynamic(light: NSColor(hex: 0xF5F5F7), dark: NSColor(hex: 0x1D1D1F))
    static let bgSide = dynamic(light: NSColor(hex: 0xF6F6F8, alpha: 0.72),
                                dark: NSColor(hex: 0x2E2E32, alpha: 0.6))
    static let bgRaised = dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x2A2A2D))
    static let bgInset = dynamic(light: NSColor(white: 0, alpha: 0.045),
                                 dark: NSColor(white: 1, alpha: 0.055))
    static let bgInset2 = dynamic(light: NSColor(white: 0, alpha: 0.07),
                                  dark: NSColor(white: 1, alpha: 0.08))
    static let bgHover = dynamic(light: NSColor(white: 0, alpha: 0.055),
                                 dark: NSColor(white: 1, alpha: 0.07))
    static let tx = dynamic(light: NSColor(hex: 0x1D1D1F), dark: NSColor(hex: 0xEDEDF0))
    static let tx2 = dynamic(light: NSColor(hex: 0x6E6E73), dark: NSColor(hex: 0x9B9BA3))
    static let tx3 = dynamic(light: NSColor(hex: 0x8A8A90), dark: NSColor(hex: 0x8A8A92))
    static let line = dynamic(light: NSColor(white: 0, alpha: 0.1),
                              dark: NSColor(white: 1, alpha: 0.08))
    static let line2 = dynamic(light: NSColor(white: 0, alpha: 0.14),
                               dark: NSColor(white: 1, alpha: 0.13))
    static let ok = NSColor(hex: 0x7FC69A)
    static let danger = dynamic(light: NSColor(hex: 0xFF3B30), dark: NSColor(hex: 0xFF6058))
    static let menuPop = dynamic(light: NSColor(hex: 0xFCFCFD, alpha: 0.86),
                                 dark: NSColor(hex: 0x303034, alpha: 0.82))

    /// Current accent (user-overridable). Computed so a fresh dynamic color is
    /// handed out after accent changes — re-fetch on `accentPublisher`.
    static var acc: NSColor {
        NSColor(name: nil) { appearance in
            let choice = Theme.accentValue
            return appearance.isDark ? NSColor(hex: choice.darkHex) : NSColor(hex: choice.lightHex)
        }
    }

    /// Accent wash used for selected pills / soft fills (design --acc-soft).
    static var accSoft: NSColor {
        NSColor(name: nil) { appearance in
            let choice = Theme.accentValue
            return appearance.isDark
                ? NSColor(hex: choice.darkHex, alpha: 0.22)
                : NSColor(hex: choice.lightHex, alpha: 0.12)
        }
    }

    // MARK: - Fonts

    static let bodyFont = NSFont.systemFont(ofSize: 13)
    /// 11pt bold for UPPERCASE section labels.
    static let sectionLabelFont = NSFont.systemFont(ofSize: 11, weight: .bold)

    static func monoFont(ofSize size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    private nonisolated static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.isDark ? dark : light
        }
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}
