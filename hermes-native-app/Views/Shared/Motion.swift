import AppKit

/// Central gate for on-screen motion. Honors the system Reduce Motion
/// accessibility setting: when it is enabled, animated closures apply their
/// changes instantly instead of tweening. Route disclosure / layout
/// transitions through here so motion stays consistent and accessible.
@MainActor
enum Motion {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Runs `changes` inside an implicit-animation group of `duration`, or
    /// applies them immediately when Reduce Motion is on.
    static func animate(_ duration: TimeInterval, _ changes: () -> Void) {
        guard !reduceMotion else {
            changes()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            changes()
        }
    }
}
