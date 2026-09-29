# Hermes Desktop (native macOS)

A native macOS AppKit wrapper app for the [hermes-agent](https://github.com/nousresearch/hermes-agent)
— the Swift/AppKit implementation of the "Hermes Desktop (AppKit)" design
(claude.ai/design project *Hermes agent macOS app*). No Electron, no web views:
NSWindow + unified NSToolbar, source-list sidebars, NSPopover/NSAlert/NSSwitch
and friends throughout.

The app replaces the fork's Electron main process as **supervisor + client**:
it spawns a local headless backend (`hermes dashboard --no-open --host 127.0.0.1
--port 0`), performs the token handshake, then drives chat over the tui_gateway
JSON-RPC 2.0 WebSocket (`/api/ws`) and management over REST (`/api/*`).

## Requirements

- macOS 26.5+, Xcode 26.6+
- A hermes install: managed (`~/.hermes/hermes-agent`) or `hermes` on PATH
  (verified against v0.17.0)

## Build & run

```
xcodebuild -project hermes.xcodeproj -scheme hermes -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/hermes-*/Build/Products/Debug/hermes.app
```

App Sandbox is disabled by design — the app spawns the Python backend and reads
`~/.hermes`. Backend logs: `~/Library/Logs/HermesDesktop/backend.log`.

### Frontend mock mode

For **frontend work without the Python backend**, Debug builds default to a mock
mode: no process is spawned and every section is populated with representative
sample data (see `Backend/MockData.swift`), including a sample chat transcript
you can reply to (canned assistant echo). To run against the real backend in
Debug instead, set `HERMES_REAL=1` in the scheme's run environment. Release
builds always use the real backend.

Individual views also have live Xcode canvas previews — open
`Previews/HermesPreviews.swift` and show the canvas. Unlike offscreen bitmap
snapshots, the preview canvas composites the macOS 26 glass materials correctly.

## Layout

- `hermes-native-app/App/` — AppKit shell: entry point, menu bar, window +
  toolbar (Dashboard grid · Chat/Skills/Automations segments · attention bell ·
  gear), theme tokens, section navigation.
- `hermes-native-app/Backend/` — supervisor (process spawn + handshake),
  JSON-RPC WebSocket client, REST client, chat session controller, app store.
- `hermes-native-app/Views/` — Chat (thread, streaming, tool cards, composer
  with permission/model pop-ups), Dashboard (attention queue + activity
  calendar), Skills hub (Skills, SOUL.md, AGENTS.md, Memory, Commands,
  Messaging, Tools & MCP), Automations, Settings, Overlays (attention popover,
  update sheet, ⌘K command bar, toasts).

## Docs

- `docs/DESIGN_SPEC.md` — design → AppKit → backend mapping (the build contract)
- `docs/AGENT_PROTOCOL.md` — the verified backend wire protocol
- `docs/UNIMPLEMENTED.md` — design features not implemented, and why
- `docs/design/hermes-appkit.html` — the design source of truth
- `docs/design/support.js` — required runtime dependency for the design source
