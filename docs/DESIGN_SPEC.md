# Hermes Desktop — design spec (from `Hermes Desktop (AppKit).dc.html`)

Source of truth: the imported "Hermes agent macOS app" handoff, file
**Hermes Desktop (AppKit).dc.html** — an interactive, pixel-faithful macOS mock
created explicitly as the build target for this Swift/AppKit app. Local copy:
[`design/hermes-appkit.html`](design/hermes-appkit.html), with its required runtime
dependency at [`design/support.js`](design/support.js). Grep those files for exact
strings, interactions, seed data, dimensions, and colors.
The design's own conventions doc says: every control maps 1:1 to a standard macOS
component; native states + focus rings; terminals/code stay dark; **no voice features**
(explicitly excluded by the user — do not add mic/TTS).

Design canvas: 1440×900 desktop preview. In the real app this is a resizable
`NSWindow` (default 1280×820, minimum 680×600); the 270pt sidebar folds as the
window narrows below 1080pt so the main content keeps a usable width.

## Global chrome

| Design element | AppKit mapping |
|---|---|
| Menu bar: Hermes · File · Edit · View · Conversation · Window · Help | Real `NSMenu` main menu |
| View menu: Overview ⌘0, Chat ⌘1, Skills ⌘2, Automations ⌘3, Needs Attention ⌘9, Toggle Sidebar ⌃⌘S, Toggle Command Bar ⌘K, Appearance: Light / Dark, Enter Full Screen ⌃⌘F | `NSMenuItem`s with key equivalents |
| Window: traffic lights, unified toolbar (42px), 270px full-height source-list sidebar w/ vibrancy and a folded state | `NSWindow` + `NSToolbar` (`.unified` style), `NSSplitViewController` with `.sidebar` item (`NSVisualEffectView` vibrancy comes free) |
| Toolbar left (over sidebar): sidebar toggle, compose (pencil), icon-only Dashboard grid; Dashboard uses an accent glyph over `--acc-soft` when active | `NSToolbarItem`s; Dashboard = borderless AppKit `NSButton`; `toggleSidebar(_:)` |
| Toolbar center: segmented control **Chat · Skills · Automations** | `NSSegmentedControl`, centered `NSToolbarItem` |
| Toolbar right: bell icon with blue count badge (attention), gear | `NSButton`s; badge drawn on the bell button; gear opens `NSMenu`: **Settings… ⌘, · Check for Updates… · About Hermes** |
| Theme: Light default; Dark supported; accent = system blue #007aff (light) / #0a84ff (dark); alt accents Purple/Pink/Orange/Green/Graphite | Respect `NSApp.effectiveAppearance`; Theme Light/Dark/Auto = set `NSApp.appearance`; accent via `NSColor.controlAccentColor` where possible, custom `Theme` palette for the in-app accent picker |
| Color restraint: neutrals + ONE accent as "pinpoint"; green #7fc69a = ok/online/done; red = error/destructive/full-access; platform identity = monochrome monogram chips (T/D/S/§/W/@/>) never brand colors | Semantic colors: `.labelColor`, `.secondaryLabelColor`, `.tertiaryLabelColor`, `.windowBackgroundColor`, `.controlBackgroundColor`, custom Theme struct for the rest |

## 1. Chat view (default landing)

**Sidebar (chat):** search `NSSearchField`; conversation list grouped TODAY /
YESTERDAY / PREVIOUS 7 DAYS (uppercase 11px section labels); rows = title +
subtitle (e.g. "Auditing auth logs · 2 subagents") + platform monogram chip
(T/S/D or › for native); selection = **solid accent + white text/sub/chip**
(source-list style); context menu on rows (pin, rename, archive, delete).
→ `NSTableView` (source list) or `NSOutlineView` with group rows.
**Backend:** `GET /api/sessions` (grouped by date), `GET /api/sessions/search?q=`,
`PATCH /api/sessions/{id}` (rename/archive), `DELETE`. Platform chip from session
origin metadata if present, else "›".

**Thread:** (scrolling `NSScrollView` + stack/table of turn views)
- Continuity divider: `— (T) Continued from Telegram — picked up here on your Mac —`
- User message: light card, right-aligned block w/ attachment chips
  (icon + name + "PNG · 248 KB") above text; "via Telegram · 8:50 PM" tag below.
- Assistant message: 24px "A" avatar (accent tint) + plain text (markdown rendered:
  paragraphs, bullets, bold/code) — no bubble.
- SUBAGENTS card: header "SUBAGENTS · 2 running in parallel"; rows: accent dot +
  name + detail + slim progress bar (accent) → custom `NSView` card;
  `NSProgressIndicator` bar style or custom layer.
- Tool terminal card (dark #1e1e20 even in light mode): header = spinner/`bash` +
  mono command + right status ("running" grey / "✓ done" green); mono body lines,
  red highlights for matches; blinking block cursor on last line.
- code_execution card: header `</>` + "code_execution python · RPC tools" + ✓ done;
  python code body (syntax-tinted); **inline figure**: light "PNG" card (#f6f6f4)
  with a bar chart (grey bars, worst bar accent) + caption.
- Learning-loop event row (LEARNED chip style, see design source `events`).
**Backend:** transcript from `session.resume` result / `GET /api/sessions/{id}/messages`;
live turn from WS events `message.start/delta/complete`, `reasoning.delta/available`,
`tool.start/progress/generating/complete` (args/result/inline_diff), `subagent.*`.
Streaming: append to `NSTextStorage`, throttle layout (~30fps bursts).

**Context strip** (floats above composer): left = removable `@chip`s
(`@ fail2ban.local ×`, `@ /etc/ssh ×`) as raised cards; right = context meter pill
"CONTEXT ▓▓ 38K / 200K" (accent fill).
**Backend:** meter from `session.usage` / `session.context_breakdown` RPC. Chips are
prompt-text `@file:`/`@folder:` refs.

**Composer** (white raised card):
- `NSTextView` auto-growing, placeholder "Reply to Hermes…".
- Left buttons: `+` (28×24 bezel square) → menu: Attach files… / Add image /
  Add a link / ─ / Skills ▸ / Tools & MCP ▸ (fly-out submenus) / ─ /
  Spawn a subagent / Schedule… → `NSButton` + `NSMenu` w/ submenus.
- `@` (bezel square) → ADD CONTEXT popover: "Pull local files, folders, a git diff
  or a URL straight into the message." File… / Folder… / Git diff / Paste URL +
  RECENT group → `NSPopover` w/ menu-like rows; File/Folder → `NSOpenPanel`.
- Permission pill: NSPopUpButton-style with dot + label + blue chevron-well.
  Modes (popover w/ title PERMISSION MODE, descriptions, check on current,
  footer "Cycle modes ⇧⇥"):
  - **Ask first** (neutral dot) "Confirms writes, shell commands, and sends. Reads and allowlisted commands run freely."
  - **Plan** (blue) "Read-only. Explores and drafts a plan — no edits, commands, or messages until you approve."
  - **Auto** (green) "Runs tools without asking, bounded by your command allowlist and container isolation."
  - **Full access** (red) "No prompts; every action auto-approved. Best only in an isolated sandbox."
  → `NSPopUpButton` (pull-down) or custom button + `NSPopover`. NOTE (from design
  docs): Hermes has NO named permission modes — this is an opinionated front-end
  over approval/allowlist/yolo primitives. Map: Ask first = default approvals;
  Full access = yolo; Auto/Plan = client-enforced (flag partial in UNIMPLEMENTED).
- Right: model picker "Hermes 405B · Max" pop-up → menu with model list
  (name + tagline rows, disabled entries allowed, e.g. "Hermes 4 · 405B FP8 —
  Currently disabled"), Effort ▸ (Low/Med/High/Max), More models ▸ →
  `NSPopUpButton`/`NSMenu`. **Backend:** `GET /api/model/options`,
  `POST /api/model/set`, per-session `session.create{model, reasoning_effort}`.
- Send: accent-filled square `NSButton` with ↑, default button styling.
**Backend:** `prompt.submit` (30-min ack timeout; completion via events); busy →
4009 (offer interrupt/steer/queue); Esc = `session.interrupt`.

## 2. Dashboard (Overview — toolbar grid button, ⌘0, NOT in the segmented control)

Header: **Dashboard** + "Here's what Hermes handled while you were away." + date.

**Sidebar (dashboard):** STATUS group (Flagged/red count 2, Awaiting/accent 1,
Done/green 9) + ACTIVITY group (Messages 3, Automations 3, Subagents 2, Learning 2)
+ PLATFORM group (Telegram 5, Discord 1, Slack 1) — all **multi-select toggle
filters**, whole-row clickable, selected = blue icon + blue label (no box), count
badges keep semantic colors; collapsible section headers (chevron right, no hover
fill, animate rotation).

**Needs attention** (count chip): cards = neutral card + **3px colored left bar**
(accent for approvals, red for flags) + icon chip + title + platform tag + time +
chevron; expand row → mono `$ command` box + description + actions:
[Allow Once (accent default)] [Always Allow] [Deny…] for approvals;
[Open Conversation] [Dismiss] for flags. Empty state: "all caught up".

**Activity — macOS Calendar day view:** eyebrow ACTIVITY + day nav (‹ Today ›);
big date header ("June 24, 2026" bold+muted year, weekday below); **all-day row**
(cron/scheduled events); hour rail (7 PM/8 PM/9 PM…) with full-width stacked event
blocks: flat inset bg + 3px left bar (neutral/red/accent) + title + platform tag +
"Awaiting" badge + clock time. Click event → jump to conversation.

**Backend:** approvals = live `approval.request` events aggregated across sessions
(client-side queue); activity/calendar synthesized from `/api/sessions` recent
messages + `/api/cron/jobs` run history (partial — flag in UNIMPLEMENTED what
can't be reconstructed).

## 3. Skills view (Capabilities hub — segmented "Skills")

**Sidebar:** IDENTITY (Personality · Context · Memory [pending count badge]) /
LIBRARY (Skills 14 · Commands 11) / CONNECTIONS (Messaging 7 · Tools & MCP 40+).
Source-list; selection solid accent.

- **Skills** grid: 2-col cards — mono name (`incident-triage`) + "used 14×" chip +
  description. Header: "Procedural memory Hermes created from experience. They
  self-improve as they're used." **Backend:** `GET /api/skills`.
- **Personality (SOUL.md):** header w/ caduceus ☤ icon tile + blurb; Preset
  segmented Default/Professional/Playful (+ amber "Custom" tag when edited);
  doc card: mono filename `SOUL.md` + "Personality · synced" + **Edit/Done**
  bezel button; read mode = rendered markdown (H1 big, H2 uppercase eyebrow,
  accent bullets); edit mode = mono `NSTextView`. Footer: "Changes here apply to
  Hermes everywhere — Telegram, Slack, CLI, and this app."
  **Backend:** read/write SOUL.md via REST fs/files API (`/api/files`, `/api/fs/*`).
- **Context (AGENTS.md):** same doc editor + file-switcher pills (AGENTS.md ·
  infra/AGENTS.md · + Add file).
- **Memory (Curator):** blurb mentions Honcho; `NSSearchField`
  ("Search memory & past sessions"); PENDING REVIEW queue — LEARNED card
  (eyebrow + summary + [Remember (accent)] [Discard]) and CONFLICT card
  ("Two signals disagree" + [Prefer Telegram (accent)] [Prefer Slack]);
  curated list grouped PREFERENCES / ENVIRONMENT / WORKING STYLE — row = dot +
  text + provenance ("Honcho · reinforced 11×" / "Inferred from 4 sessions" /
  "Stated directly") + hover-red **Forget**. Forget → undo toast.
  **Backend:** `/api/memory*` where available; pending-review queue likely has no
  backend → UNIMPLEMENTED candidate.
- **Commands:** "+ New command" link button; CUSTOM group (/standup /ship /triage,
  Edit ›); BUILT-IN group with `NSSwitch` per row (/compress /usage /insights
  /retry /undo /stop /new on; /help off). **Backend:** `commands.catalog` RPC
  (read); toggling built-ins per-app → likely client-side only.
- **Messaging:** platform cards 2-col — monogram tile + name + detail + trailing
  status: green "Connected" pill or bezel "Connect" button. Seed: Telegram
  (@yourhandle · home) / Discord (2 servers) / Slack (acme.slack.com) connected;
  WhatsApp (Link a number), Signal (Link a device), Email (IMAP / SMTP) connect;
  CLI / TUI (Always on) connected. Blurb: "one gateway process bridges every
  channel…" (no voice mention in app). **Backend:** `/api/messaging/platforms`,
  gateway status from `/api/status`.
- **Tools & MCP:** rows — status dot (green on / grey off) + name + detail +
  `NSSwitch`: Filesystem (8 tools · read, write, search), Shell / Bash (core ·
  streaming output), Web search (Firecrawl · Tool Gateway), Cloud browser
  (Browser Use · Tool Gateway), Image generation (FAL · Tool Gateway, off),
  GitHub (MCP · 12 tools), Postgres (MCP · 6 tools), Linear (MCP · available, off).
  **Backend:** `/api/tools/toolsets*`, `/api/mcp/servers*`.

## 4. Automations view

**Sidebar:** SCHEDULES — All 4 / Active 3 / Paused 1 (dot + label + count).
**Content:** header + "Cron tasks described in natural language, running unattended
and delivering to any platform." + "+ New schedule" link. Cards: title + status tag
(✓ last run ok green / ⚠ flagged last run red / "Paused" grey) + schedule line
("Every Monday at 9:00 AM" + mono cron chip `0 9 * * 1` + "→ Slack" delivery chip)
+ "Next run · …" + trailing `NSSwitch`. Context menu (run now, pause, edit, delete).
**Backend:** `/api/cron/jobs` CRUD + pause/resume/trigger.

## 5. Settings view (gear → Settings…, no segmented control shown)

**Sidebar:** "Settings" header; categories with icon tiles: Agent / Compute /
Providers / Appearance / About; selection solid accent.
Grouped rows (title + subtitle left, value + › right) — `NSTableView` inset-grouped
look:
- **Agent · BEHAVIOR:** Default model → "Hermes 4 · 405B ›" (real: current model);
  Personality → "Default ›" (jumps to Skills▸Personality); Learning loop → "On ›";
  Context files → "2 files ›" (jumps to Context).
- **Compute · EXECUTION & SANDBOX:** Terminal backend → "Modal · serverless ›"
  (6 backends: local/Docker/SSH/Singularity/Modal/Daytona); Max parallel
  subagents → "4 ›"; Command approval → "Allowlist ›"; Container isolation → "On ›".
  **Backend:** `config.get/set`.
- **Providers · MODEL PROVIDERS:** Nous Portal "300+ models · Tool Gateway" →
  Connected ›; OpenRouter "200+ models" → Key set ›; Anthropic "Claude family" →
  Key set ›; Add provider… "OpenAI, Moonshot, z.ai, custom endpoint".
  **Backend:** `GET /api/providers/oauth`, `/api/env`, `POST /api/model/set`.
- **Appearance:** Theme → Light/Dark/Auto `NSSegmentedControl`; Accent color →
  6 swatch buttons (blue✓/purple/pink/orange/green/graphite).
- **About · HERMES DESKTOP:** Version → "1.4.0" (real: app + backend versions);
  Release channel → "Stable · Auto-update"; Documentation →
  hermes-agent.nousresearch.com Open ›; Built by → "Nous Research · MIT License".

## 6. Overlays

- **Attention popover** (bell): `NSPopover` w/ beak, 374pt wide, title "Needs
  attention 3" + "Across all platforms"; always-expanded cards (same content as
  dashboard cards incl. mono cmd box + action buttons); footer "Open in Overview ⌘0".
- **Software Update sheet** (window-modal, drops from top = `beginSheet`): stages —
  checking (12-spoke macOS spinner = `NSProgressIndicator` spinning) → available
  (app icon, "Hermes Desktop / A new version is available", "Version 1.5.0 ·
  24.3 MB · Jun 30, 2026", WHAT'S NEW release-notes card, [Later] [Update & Restart
  (accent default)]) → updating (progress bar + steps Pulling/Updating/Restarting
  w/ ✓/spinner) → done (green ✓ + Done). **Backend:** `GET /api/hermes/update/check`,
  `POST /api/hermes/update`, `POST /api/gateway/restart`.
- **Deny confirmation** (`NSAlert`): app icon badged w/ caution triangle, bold
  "Deny this command?", request title, mono cmd box, fineprint "Hermes won't run
  it…", [Cancel] [Deny (default)] — stock NSAlert = no red destructive fill.
- **Undo toast:** frosted floating pill bottom-center of content area — text +
  accent **Undo** + ×; auto-dismiss 5s. For Allow once ("Allowed once"), Always
  allow ("Added to allowlist"), Dismiss ("Dismissed"), memory Forget ("Memory
  forgotten"). Deny uses the alert instead, no toast. → custom `NSView` overlay
  (or `NSPopover`-less floating panel).
- **Command Bar ⌘K** (View menu "Toggle Command Bar") — design has no dedicated
  mock beyond the menu item; implement a minimal floating command palette or flag
  as UNIMPLEMENTED.

## 7. Shared sidebar footer (all workspace views, hidden in Settings)

Pinned to sidebar bottom, flush (hairline dividers, no card):
- **USAGE** collapsible: header "USAGE — $48.20 / $100 ›"; always-visible accent
  spend bar; caption "48% of monthly budget · resets Jul 1"; expanded: Tokens bar
  "4.2M / 10M" + breakdown rows (Models · Nous Portal $31.40 / Tool Gateway $12.80 /
  Compute · Modal $4.00). **Backend:** `GET /api/analytics/usage?days=` — budget
  concept doesn't exist server-side → show real usage, budget = UNIMPLEMENTED.
- **Hermes online** collapsible: pulse dot + "Hermes online" ›; expanded facts:
  BACKEND "Modal · idle" / HOME "Telegram" / MODEL "405B · Max" / RUNNING
  "2 subagents" / NEXT "Auth log audit · 3:00 AM". **Backend:** `/api/status`,
  `session.info`, cron next-run.

## Seed/demo data

All demo strings (conversations, events, approvals, skills, memories, autos,
tools, messaging) live in the design source `state` — grep `state = {` in
`hermes-appkit.html`. Use them only as placeholder previews where real backend
data is absent, and prefer real data everywhere.
