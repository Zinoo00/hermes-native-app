import AppKit

// Manual bootstrap: no storyboard/nib, no @main. Delegate must outlive run().
// Top-level code runs on the main thread; assumeIsolated makes that explicit so
// the main-actor-isolated NSApplicationDelegate conformance is usable here.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    _ = delegate // keep the delegate alive for the lifetime of run()
}
