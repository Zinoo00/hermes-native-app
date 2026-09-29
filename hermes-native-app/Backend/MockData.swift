#if DEBUG
import Foundation

//  MockData.swift
//
//  Frontend-first sample data. Lets the whole UI run fully populated WITHOUT the
//  Python backend — no process spawn, no sockets. DEBUG builds default to this
//  (see AppDelegate); set HERMES_REAL=1 to use the real backend instead.
//
//  Model values are built through the real `init(json:)` parsers so they stay in
//  lock-step with the wire format; transcript pieces use their memberwise inits.

@MainActor
enum MockData {
    /// Dummy connection so `connectionState == .ready` (nothing dials it).
    static var connection: BackendConnection {
        BackendConnection(
            baseURL: URL(string: "http://127.0.0.1:0")!,
            wsURL: URL(string: "ws://127.0.0.1:0")!,
            token: "mock",
            port: 0
        )
    }

    // MARK: Sidebar / lists

    static func sessions() -> [SessionSummary] {
        [
            ["id": "s-hermes-native", "title": "Native macOS wrapper for Hermes",
             "preview": "Let's map the toolbar to a unified NSToolbar and keep the sidebar on the macOS 26 glass style.",
             "model": "claude-opus-4-8", "source": "desktop", "last_active": 1_751_450_400,
             "message_count": 42, "tool_call_count": 17, "input_tokens": 486_000, "output_tokens": 78_000,
             "is_active": true],
            ["id": "s-auth-refactor", "title": "Refactor the token handshake",
             "preview": "Extracted the dashboard token scrape into its own actor and added a reconnect test.",
             "model": "claude-opus-4-8", "source": "cli", "last_active": 1_751_360_000,
             "message_count": 28, "tool_call_count": 9],
            ["id": "s-trip", "title": "Lisbon vs. Porto in August",
             "preview": "Compared flight prices and walkability; Porto wins on both for late August.",
             "model": "claude-haiku-4-5", "source": "webui", "last_active": 1_751_180_000,
             "message_count": 12, "tool_call_count": 2],
            ["id": "s-copy", "title": "Tighten dashboard microcopy",
             "preview": "Rewrote the empty states to be shorter and friendlier across every section.",
             "model": "claude-opus-4-8", "source": "desktop", "last_active": 1_751_020_000,
             "message_count": 6, "tool_call_count": 0],
            ["id": "s-sql", "title": "Explain this slow query",
             "preview": "Added a composite index on (tenant_id, created_at) and the scan dropped to a seek.",
             "model": "claude-opus-4-8", "source": "cli", "last_active": 1_750_760_000,
             "message_count": 18, "tool_call_count": 5],
        ].compactMap { SessionSummary(json: $0) }
    }

    static func skills() -> [Skill] {
        [
            ["name": "apple-notes", "description": "Manage Apple Notes via memo CLI: create, search, edit.", "category": "Apple", "enabled": true],
            ["name": "apple-reminders", "description": "Apple Reminders via remindctl: add, list, complete.", "category": "Apple", "enabled": true],
            ["name": "findmy", "description": "Track Apple devices/AirTags via FindMy.app on macOS.", "category": "Apple", "enabled": true],
            ["name": "imessage", "description": "Send and receive iMessages/SMS via the imsg CLI on macOS.", "category": "Messaging", "enabled": true],
            ["name": "claude-code", "description": "Delegate coding to Claude Code CLI (features, PRs).", "category": "Coding", "enabled": true],
            ["name": "codex", "description": "Delegate coding to OpenAI Codex CLI (features, PRs).", "category": "Coding", "enabled": false],
            ["name": "hermes-agent", "description": "Configure, extend, or contribute to Hermes Agent.", "category": "Meta", "enabled": true],
            ["name": "hermes-webui-config", "description": "Configure and customize the Hermes WebUI app safely.", "category": "Meta", "enabled": true],
            ["name": "opencode", "description": "Delegate coding to OpenCode CLI (features, PR review).", "category": "Coding", "enabled": false],
            ["name": "computer-use", "description": "Drive the user's desktop in the background — clicking, typing, scrolling — without stealing the cursor or switching Spaces. Cross-platform, works with any tool-capable model.", "category": "System", "enabled": true],
            ["name": "architecture-diagram", "description": "Dark-themed SVG architecture/cloud/infra diagrams as HTML.", "category": "Docs", "enabled": true],
            ["name": "ascii-art", "description": "ASCII art: pyfiglet, cowsay, boxes, image-to-ascii.", "category": "Fun", "enabled": true],
            ["name": "ascii-video", "description": "ASCII video: convert video/audio to colored ASCII MP4/GIF.", "category": "Fun", "enabled": true],
            ["name": "baoyu-infographic", "description": "Infographics: 21 layouts x 21 styles.", "category": "Docs", "enabled": false],
            ["name": "web-search", "description": "Search the web and synthesize cited answers.", "category": "Research", "enabled": true],
            ["name": "pdf-extract", "description": "Pull text and tables out of PDFs and scans.", "category": "Docs", "enabled": true],
        ].compactMap { Skill(json: $0) }
    }

    static func cronJobs() -> [CronJob] {
        [
            ["id": "c-brief", "name": "Morning briefing",
             "schedule": ["kind": "cron", "expr": "0 8 * * *"], "schedule_display": "Every day at 8:00 AM",
             "enabled": true, "last_status": "ok", "deliver": "imessage",
             "prompt": "Summarize my calendar, unread priority mail, and overnight PR activity."],
            ["id": "c-digest", "name": "Weekly repo digest",
             "schedule": ["kind": "cron", "expr": "0 9 * * 1"], "schedule_display": "Mondays at 9:00 AM",
             "enabled": true, "last_status": "ok", "deliver": "slack",
             "prompt": "Digest merged PRs, open issues, and CI health for hermes-native-app."],
            ["id": "c-backup", "name": "Nightly backup check",
             "schedule": ["kind": "cron", "expr": "0 2 * * *"], "schedule_display": "Every day at 2:00 AM",
             "enabled": false, "last_status": "error", "last_error": "SSH timeout to backup host",
             "deliver": "none", "prompt": "Verify last night's Restic snapshot completed and prune old ones."],
        ].compactMap { CronJob(json: $0) }
    }

    // MARK: Analytics / model / status

    static func usage() -> AnalyticsUsage {
        AnalyticsUsage(json: [
            "daily": [
                ["day": "2026-06-27", "input_tokens": 190_000, "output_tokens": 31_000, "estimated_cost": 1.7, "sessions": 3, "api_calls": 44],
                ["day": "2026-06-28", "input_tokens": 210_000, "output_tokens": 40_000, "estimated_cost": 1.9, "sessions": 4, "api_calls": 52],
                ["day": "2026-06-29", "input_tokens": 180_000, "output_tokens": 33_000, "estimated_cost": 1.6, "sessions": 3, "api_calls": 41],
                ["day": "2026-06-30", "input_tokens": 260_000, "output_tokens": 51_000, "estimated_cost": 2.4, "sessions": 6, "api_calls": 63],
                ["day": "2026-07-01", "input_tokens": 300_000, "output_tokens": 60_000, "estimated_cost": 2.85, "sessions": 7, "api_calls": 70],
            ],
            "by_model": [
                ["model": "claude-opus-4-8", "input_tokens": 900_000, "output_tokens": 175_000, "estimated_cost": 7.1, "sessions": 18, "api_calls": 210],
                ["model": "claude-haiku-4-5", "input_tokens": 240_000, "output_tokens": 40_000, "estimated_cost": 1.65, "sessions": 5, "api_calls": 60],
            ],
            "totals": [
                "total_input": 1_140_000, "total_output": 215_000, "total_cache_read": 160_000,
                "total_estimated_cost": 8.75, "total_actual_cost": 8.75, "total_sessions": 23, "total_api_calls": 270,
            ],
        ])
    }

    static func modelInfo() -> ModelInfo {
        ModelInfo(json: [
            "model": "claude-opus-4-8", "provider": "anthropic", "effective_context_length": 200_000,
            "capabilities": [
                "supports_tools": true, "supports_vision": true, "supports_reasoning": true,
                "context_window": 200_000, "max_output_tokens": 64_000, "model_family": "claude",
            ],
        ])
    }

    static func status() -> StatusResponse {
        StatusResponse(json: [
            "version": "0.17.0", "release_date": "2026-06-20", "active_sessions": 1,
            "gateway_running": true, "gateway_state": "running", "can_update_hermes": true,
            "gateway_platforms": [
                "cli": ["state": "connected"],
                "webui": ["state": "connected"],
                "imessage": ["state": "connected"],
            ],
        ])
    }

    // MARK: Focused chat transcript

    static func runtimeInfo() -> SessionRuntimeInfo {
        SessionRuntimeInfo(json: [
            "model": "claude-opus-4-8", "provider": "anthropic", "reasoning_effort": "high",
            "cwd": "~/Desktop/Codes/side-projects/hermes-native-app", "branch": "main",
            "title": "Native macOS wrapper for Hermes", "running": false, "desktop_contract": 2,
            "usage": usageStatsJSON,
        ])
    }

    static func usageStats() -> UsageStats { UsageStats(json: usageStatsJSON) }

    private static let usageStatsJSON: JSONValue = [
        "model": "claude-opus-4-8", "input": 486_000, "output": 78_000, "reasoning": 22_000,
        "total": 564_000, "calls": 17, "context_used": 112_000, "context_max": 200_000,
        "context_percent": 56, "compressions": 0, "active_subagents": 0, "cost_usd": 3.42,
    ]

    static func transcript() -> [TranscriptItem] {
        [
            TranscriptItem(kind: .user(UserMessage(
                text: "Let's build the native macOS wrapper. Keep the sidebar on the new macOS 26 glass style and map the toolbar 1:1 to a unified NSToolbar.",
                timestamp: Date(timeIntervalSince1970: 1_751_446_800), source: "desktop"))),
            TranscriptItem(kind: .assistant(AssistantMessage(
                text: "Good plan. I'll use `NSSplitViewItem(sidebarWithViewController:)` so the sidebar gets the floating inset glass material for free, and a single `NSToolbar` with a tracking separator pinned to the divider. The section switcher becomes a centered `NSSegmentedControl`.\n\nStarting with the window + split controller scaffold now.",
                reasoning: "The design maps cleanly to stock AppKit. Sidebar glass is a split-item style; the toolbar's centered switcher is a segmented control with centeredItemIdentifiers.",
                isStreaming: false, status: "complete", usage: nil))),
            TranscriptItem(kind: .tool(ToolCard(
                toolID: "t-1", name: "edit_file", context: "MainSplitViewController.swift",
                argsText: "path: App/MainSplitViewController.swift",
                args: ["path": "App/MainSplitViewController.swift"],
                result: .null,
                resultText: "Updated 1 file (+14 −6).",
                summary: "Switch the sidebar item to the macOS 26 glass style",
                inlineDiff: "+ let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarContainer)\n+ sidebarItem.minimumThickness = Self.sidebarWidth\n- let sidebarItem = NSSplitViewItem(viewController: sidebarContainer)",
                progressPreview: nil, durationSeconds: 1.3, status: .complete))),
            TranscriptItem(kind: .assistant(AssistantMessage(
                text: "Sidebar is on the glass style and the toolbar builds. Next I'll wire the section coordinator so the segmented control and the Dashboard pill swap the content pane.",
                reasoning: "", isStreaming: false, status: "complete", usage: usageStats()))),
            TranscriptItem(kind: .user(UserMessage(
                text: "The window opens really small and won't grow. Can you look?",
                timestamp: Date(timeIntervalSince1970: 1_751_448_600), source: "desktop"))),
            TranscriptItem(kind: .tool(ToolCard(
                toolID: "t-2", name: "run_command", context: "resize probe",
                argsText: "HERMES_RESIZE_PROBE=1 ./hermes",
                args: ["cmd": "HERMES_RESIZE_PROBE=1 ./hermes"],
                result: .null,
                resultText: "BEFORE window.frame=(221,229 1130x720)\nAFTER setFrame(6000x4000) -> (0,87 6000x862)",
                summary: "Probe the window's real resize limits",
                inlineDiff: nil, progressPreview: nil, durationSeconds: 2.1, status: .complete))),
            TranscriptItem(kind: .assistant(AssistantMessage(
                text: "Found it — assigning `contentViewController` after the window was created snapped it down to the split view's minimum fitting size on launch. There's no real width cap (it grew to 6000 in the probe). I'll size and center the window *after* attaching the content controller, defaulting to 1280×820.",
                reasoning: "The fitting-size snap on setContentViewController is the classic cause of a window opening at its minimum. Sizing after assignment fixes it.",
                isStreaming: false, status: "complete", usage: nil))),
        ]
    }
}
#endif
