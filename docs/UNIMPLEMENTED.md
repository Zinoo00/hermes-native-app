# Features not (fully) implemented vs. the design

The design (`Hermes Desktop (AppKit).dc.html`) mocks several capabilities that the
hermes-agent backend does not expose, or that a native client cannot deliver
faithfully. Everything below was verified against the fork's server source
(`tui_gateway/server.py`, `hermes_cli/web_server.py`, `web/src/lib/api.ts`)
rather than assumed. The app never fabricates the design's demo content —
where the backend has no data, it renders honest empty states.

## No backend support

- **Memory "Pending review" queue** (LEARNED/CONFLICT cards with
  Remember · Discard · Prefer-X actions). There is no pending-memory-review API —
  `GET /api/memory` is provider status only; `/api/learning/*` stores
  already-curated nodes. The Memory tab lists curated items with Forget; the
  review queue renders only if such data ever appears (today: never). Also:
  Forget has **no undo** (DELETE is permanent server-side, no re-create API) and
  provenance shows "file · date" instead of the design's "Honcho · reinforced 11×"
  (no reinforcement counts in the API).
- **Monthly budget in Usage & cost** ("$48.20 / $100 · resets Jul 1").
  `GET /api/analytics/usage` has token/cost totals but no budget concept.
  The sidebar footer shows real 30-day spend/tokens instead.
- **Named permission modes** (Ask first / Plan / Auto / Full access).
  Hermes's security model is approval-allowlist + container isolation — no mode
  primitive (the design's own notes call the pill "an opinionated front-end").
  Implemented as client-side policy: *Ask first* (default) surfaces approvals;
  *Auto* auto-answers approvals with "session"; *Full access* answers "always".
  **Plan is shown but disabled** ("Requires backend support") — read-only turns
  need agent cooperation that doesn't exist. Clarify/sudo/secret requests are
  never auto-answered in any mode.
- **Cross-platform attention feed** ("Across all platforms").
  `approval.request` events only reach the transport owning the session, so the
  queue only aggregates approvals from sessions this app opened. Telegram/Slack
  approvals never appear. Attention cards also lack platform tags (events carry
  no platform metadata).
- **"Flag" attention cards** (anomaly flags with Open Conversation/Dismiss).
  The gateway emits no flag events; red treatment is applied to failed cron
  runs and full-access sudo requests instead. Cron "flagged" is inferred from
  `last_status`/`last_error` text — no explicit anomaly concept exists.
- **Activity calendar fidelity.** No activity-feed API exists: no per-message
  events ("Replied on Telegram"), no learning-loop events, no subagent-finished
  feed. The calendar synthesizes one event per session (at `last_active`) plus
  cron run history; sessions with a parent session stand in for the Subagents
  lens; the Learning lens shows a real count of 0.
- **Slash-command management.** `commands.catalog` is read-only (custom commands
  live in `config.yaml` `quick_commands`): "+ New command" and "Edit ›" are
  disabled with tooltips; built-in toggles persist client-side only and affect
  nothing server-side.
- **Cross-platform conversation continuity.** Gateway (messaging) conversations
  are not resumable as desktop sessions. The "Continued from <Platform>" divider
  renders only from a session's own origin metadata; per-message "via Telegram ·
  8:50 PM" tags are absent for replayed history (the transcript API carries no
  per-message source).
- **code_execution inline figure** (the light "PNG" bar-chart card): the backend
  emits no inline-figure payload on tool events.
- **Update sheet fidelity.** `GET /api/hermes/update/check` returns no new
  version number, size, date, or release notes — the sheet shows
  "N releases behind" + the backend's message text; staged
  Pulling/Updating/Restarting steps are replaced by an indeterminate bar with
  the update action's streaming output line.
- **Messaging "Connect" flows.** No in-app credential flow exists; Connect opens
  the platform's setup docs. The CLI/TUI "Always on" card is synthesized (the
  app itself is a live gateway client). Provider subtitles show real model
  counts, not the design's marketing copy; "Key set" vs "Connected" is inferred.
- **Settings values that don't exist server-side:** SOUL.md presets
  (Default/Professional/Playful) are app-local content templates — the backend
  has no preset concept; "Learning loop" maps to `memory.memory_enabled`;
  "Command approval" and "Container isolation" are derived (allowlist default /
  container-backend implies isolation); "Release channel" shows the real
  install method (e.g. "git · self-update"), not a channel; Context-files count
  is not enumerable (row shows "Open ›").
- **Session pinning** is client-side (UserDefaults) — sessions have no pin field.
  "used N×" chips on skills appear only when the learning graph has a use count
  (`GET /api/skills` itself carries none).
- **Subagent progress bars** map coarse status → fraction (events carry no
  percent). "Spawn a subagent" seeds prompt text (no spawn RPC).
- **Model switching mid-session** — no RPC exists; the picker applies to the
  next session created. Global `/api/model/set` deliberately not called from
  the composer to avoid mutating shared config.

## Native/AppKit constraints

- **Per-app accent at runtime.** Stock controls (NSSwitch, default buttons,
  source-list selection) follow the system/app accent; no public API re-tints
  them at runtime. The in-app accent picker re-tints custom-drawn elements only.
- **Red destructive filled button** in the Deny alert: stock NSAlert has no
  destructive fill (the design itself notes this and uses the blue default);
  the caution-badged app icon is likewise the system default.
- **Uniform corner radii** on chat bubbles (design mixes per-corner radii;
  CALayer's cornerRadius is uniform).
- Cosmetic animations skipped: blinking terminal cursor / live tail in tool
  cards, collapsible date-group headers in the chat sidebar.

## Deliberately excluded

- **Voice features** (mic, TTS) — explicitly excluded by the design owner,
  though the backend exposes `/api/audio/*`.
- **Desktop pet companion** — Electron-app feature, not in the AppKit design.

## Deferred (backend exists, not wired in v1)

- Remote gateway mode (OAuth cookies + single-use WS tickets) — the app always
  spawns a local backend.
- Multiple profiles (one backend process per profile).
- First-run bootstrap installer of the hermes runtime — the app requires an
  existing install (managed `~/.hermes` or `hermes` on PATH).
- In-app editing of Compute settings (terminal backend, subagent cap) — values
  display from `config.yaml`; editing happens outside the app.
- Session export, bulk delete, and the sessions FTS search inside the Memory tab
  (chat-sidebar search covers FTS).

## Known runtime caveats

- If the app process is force-killed (SIGKILL — bypassing normal Quit), the
  spawned `hermes dashboard` child is orphaned and keeps running; normal Quit
  terminates it cleanly. A parent-death watch is future work.
- ~25 Swift-6-mode concurrency warnings remain in Backend files (benign in the
  project's Swift 5 mode; each becomes an error under Swift 6 language mode).
