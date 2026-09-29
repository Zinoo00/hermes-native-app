import AppKit

/// Permission-free window snapshots for automated visual verification.
/// Enabled by launching with HERMES_SNAPSHOT_DIR=<dir> — walks every section,
/// renders the window's own view tree to PNGs (no Screen Recording needed),
/// then terminates the app. Debug tooling only; inert in normal launches.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(coordinator: SectionCoordinator, window: NSWindow?) {
        guard let dir = ProcessInfo.processInfo.environment["HERMES_SNAPSHOT_DIR"],
              !dir.isEmpty, let window else { return }
        let settleSeconds = Double(ProcessInfo.processInfo.environment["HERMES_SNAPSHOT_SETTLE"] ?? "") ?? 12

        Task {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            // Let the backend spawn/connect so sidebars carry real data.
            try? await Task.sleep(for: .seconds(settleSeconds))

            let plan: [(String, AppSection)] = [
                ("01-chat", .chat),
                ("02-dashboard", .dashboard),
                ("03-skills", .skills),
                ("04-automations", .automations),
                ("05-settings", .settings),
            ]
            // Real capture composites macOS 26 glass (cacheDisplay cannot); set
            // HERMES_REALCAP=1 to shell out to /usr/sbin/screencapture per section.
            let realCap = ProcessInfo.processInfo.environment["HERMES_REALCAP"] == "1"
            for (name, section) in plan {
                coordinator.navigate(to: section)
                try? await Task.sleep(for: .seconds(3))
                if realCap {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .seconds(0.6))
                    screencaptureWindow(window, to: "\(dir)/\(name).png")
                } else {
                    capture(window: window, to: "\(dir)/\(name).png")
                }
                dumpHierarchy(window: window, to: "\(dir)/\(name).txt",
                              note: "requested=\(section) current=\(coordinator.currentSection)")
            }
            coordinator.navigate(to: .chat)
            try? await Task.sleep(for: .seconds(0.5))
            NSApp.terminate(nil)
        }
    }

    private static func dumpHierarchy(window: NSWindow, to path: String, note: String = "") {
        var out = "\(note)\nappearance=\(window.effectiveAppearance.name.rawValue) mode=\(Theme.shared.appearanceMode)\n"
        out += "windowBG=\(window.backgroundColor?.description ?? "nil")\n"
        func walk(_ v: NSView, _ depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            let cls = String(describing: type(of: v))
            let f = v.frame
            var flags: [String] = []
            if v.isHidden { flags.append("HIDDEN") }
            if f.width < 2 || f.height < 2 { flags.append("ZERO") }
            if let layer = v.layer, let bg = layer.backgroundColor { flags.append("bg=\(NSColor(cgColor: bg)?.description ?? "?")") }
            out += "\(pad)\(cls) (\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))) \(flags.joined(separator: " "))\n"
            // Keep dumps readable: cap breadth on huge subtrees.
            for sub in v.subviews.prefix(30) { walk(sub, depth + 1) }
        }
        if let content = window.contentView { walk(content.superview ?? content, 0) }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Captures the real on-screen window (glass composited) via the system
    /// screencapture tool, targeting this window's CGWindowID (-l). Requires
    /// Screen Recording permission for the launching terminal.
    private static func screencaptureWindow(_ window: NSWindow, to path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x no sound, -o no shadow, -l<id> capture just this window.
        process.arguments = ["-x", "-o", "-l\(window.windowNumber)", path]
        try? process.run()
        process.waitUntilExit()
    }

    private static func capture(window: NSWindow, to path: String) {
        // The frame view (contentView's superview) includes titlebar + toolbar.
        guard let content = window.contentView, let frameView = content.superview else { return }
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
