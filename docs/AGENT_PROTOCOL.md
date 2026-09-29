# Hermes backend protocol contract (native macOS app)

The app replaces the Electron main process (`hermes-agent/apps/desktop/electron/main.cjs`)
as **process supervisor + JSON-RPC client**. Verified live on 2026-07-02 against the
managed install (`~/.local/bin/hermes`, v0.17.0) on this machine.

## Spawn

```
hermes [--profile <name>] serve --host 127.0.0.1 --port 0        # v0.18+
hermes [--profile <name>] dashboard --no-open --host 127.0.0.1 --port 0   # fallback, v0.17 (VERIFIED)
```

Runtime resolution order (mirrors Electron): explicit override → managed install
(`~/.hermes/hermes-agent` with `.hermes-bootstrap-complete` marker) → `hermes` on PATH
(probe with `--version`). The installed v0.17.0 has **no `serve` subcommand** — probe
`hermes serve --help` or catch the argparse error and fall back to `dashboard --no-open`.

Environment (all required):
- `HERMES_HOME` — propagate always (default `~/.hermes`); children that miss it write to the default profile.
- `HERMES_DASHBOARD_SESSION_TOKEN` — mint 32 random bytes, base64url. Server adopts it.
- `HERMES_DESKTOP=1` — enables in-process cron ticks.
- `TERMINAL_CWD` — workspace dir; also set the child's cwd.
- Repaired `PATH` for Finder-launched apps: prepend `~/.hermes/node/bin`, `~/.hermes/hermes-agent/venv/bin`, `/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin`, then system dirs.

## Handshake (VERIFIED)

1. Read child stdout line-by-line for `^HERMES_DASHBOARD_READY port=(\d+)$`.
   Timeout 90 s — first launch may build the web SPA (Node required) before binding.
   `HERMES_DESKTOP_READY_FILE` is **not supported by v0.17.0** — stdout parsing is the reliable path.
2. Poll `GET http://127.0.0.1:<port>/api/status` with header `X-Hermes-Session-Token: <token>` until 200.
3. `GET /` and scrape `window.__HERMES_SESSION_TOKEN__ = "<token>"`; prefer the served token.
   Served token ≠ pinned while your child is dead ⇒ foreign process on the port ⇒ abort.
4. Open `ws://127.0.0.1:<port>/api/ws?token=<token>`. First server frame is the
   `gateway.ready` event. Auth failure closes 4401/4403.

## Wire format (WebSocket, one JSON object per text frame, JSON-RPC 2.0)

- Request: `{"jsonrpc":"2.0","id":<int>,"method":"...","params":{...}}`
- Response: `{"jsonrpc":"2.0","id":<same>,"result":{...}}` or `{"error":{"code":N,"message":"..."}}`.
  Responses arrive **out of order** — match strictly by id.
- Event (no id): `{"jsonrpc":"2.0","method":"event","params":{"type":"<event>","session_id":"<sid>","payload":{...}}}`
- Error codes: -32700/-32600/-32601/-32602/-32000 standard; 4009 session busy; 4090 session limit; 5032 agent init timeout.
- Events missing `session_id` belong to the focused turn, EXCEPT `subagent.*` (drop those).

## Chat lifecycle (VERIFIED through session.create/close)

1. `session.create {"cols":96,"cwd":"/abs","source":"desktop", "model"?, "provider"?, "reasoning_effort"?, "fast"?}`
   → `{"session_id":"<8-hex live id>","stored_session_id":"<durable id>","info":{"desktop_contract":2,"model":...}}`.
   Gate on `info.desktop_contract >= 2`. Live id is per-connection; stored id is used by REST + resume.
2. `session.resume {"session_id":"<storedId>"}` → NEW live id + full `messages` transcript replay.
3. `prompt.submit {"session_id":"<liveId>","text":"..."}` — fire-and-forget; ack can take minutes
   (Electron uses a 30-minute timeout). Completion is signaled by `message.complete`, never the RPC result.
   Recovery: 4009 busy → offer interrupt/steer/queue; "session not found" → resume stored id, retry.
4. `session.interrupt` to cancel, `session.steer` mid-turn, `session.close` on window close.

## Streaming events per turn (in order)

`message.start {}` → `thinking.delta {text}` (spinner, ignorable) / `reasoning.delta {text}` →
`tool.start {tool_id,name}` → `tool.progress` / `tool.generating` →
`tool.complete {tool_id,name,args,result,summary?,inline_diff?,todos?,duration_s?}` →
`message.delta {text}` (bursts, server-coalesced ~30 fps — append to NSTextStorage incrementally) →
`message.complete {text,usage,status:"complete|interrupted|error"}`.
Also: `reasoning.available {text}` (replaces accumulated), `error {message}`, `status.update {kind}`,
`session.info {model,cwd,branch,usage,running,...}` (drives status UI), `session.title`, `moa.*`, `subagent.*`.

## Blocking interaction events — ALWAYS answer or the turn stalls server-side

| Event | Respond with | Server timeout |
|---|---|---|
| `approval.request {command,description,allow_permanent,request_id}` | `approval.respond {session_id, choice:"once"\|"session"\|"always"\|"deny"}` | ~300 s → tool BLOCKED |
| `clarify.request {request_id,question,choices?}` | `clarify.respond {request_id,answer}` | — |
| `sudo.request {request_id}` | `sudo.respond {request_id,password}` | 120 s |
| `secret.request {request_id,prompt,env_var}` | `secret.respond {request_id,value}` | — |
| `terminal.read.request {request_id,start?,count?}` | `terminal.read.respond {request_id,text}` | 30 s |

## Attachments

`image.attach {path}` / `file.attach` / `pdf.attach` (local paths; `image.attach_bytes` base64 for
remote mode). Reference in prompt text as `@file:/abs/path` / `@image:` tokens.

## Reconnect semantics

On WS drop sessions are parked and reaped after ~20 s (`HERMES_TUI_WS_ORPHAN_REAP_GRACE_S`).
After sleep/wake: reconnect (backoff 1,2,4…15 s cap), re-check `/api/status`, `session.resume`
each open session — live ids change on every resume, keep the live↔stored map.
uvicorn WS pings (30 s/60 s) are handled by URLSessionWebSocketTask automatically.

## REST surface (same port, header `X-Hermes-Session-Token`)

- `GET /api/status` → version, gateway state (VERIFIED)
- `GET /api/sessions?limit&offset&archived&order`, `GET /api/sessions/search?q=`,
  `GET/PATCH/DELETE /api/sessions/{id}` (PATCH `{"title"}` / `{"archived"}`),
  `GET /api/sessions/{id}/messages` → `{messages:[{role,content:<string|blocks>,reasoning?,tool_calls?,timestamp?}]}`
- `GET/PUT /api/config`, `/api/config/schema`; `GET/PUT/DELETE /api/env`, `POST /api/providers/validate`
- Provider OAuth: `GET /api/providers/oauth`, `POST /api/providers/oauth/{id}/start`
  → `{pkce:{auth_url}|device_code:{user_code,verification_url,poll_interval}|loopback:{auth_url}}`,
  `POST …/submit`, `GET …/poll/{sid}`
- `GET /api/model/info|options`, `POST /api/model/set {scope:"main"|"auxiliary",provider,model,api_key?}`
- `/api/cron/jobs` CRUD; `GET /api/analytics/usage?days=`;
  `POST /api/audio/transcribe {data_url,mime_type}` → `{transcript}`; `POST /api/audio/speak {text}` → `{data_url}`

Typed references in the fork: `apps/shared/src/json-rpc-gateway.ts` (client),
`ui-tui/src/gatewayTypes.ts` (event/RPC union), `web/src/lib/api.ts` (REST),
`tui_gateway/server.py` + `tui_gateway/ws.py` + `hermes_cli/web_server.py` (server truth).

## Packaging constraints

App Sandbox must be **disabled** (spawns `~/.hermes` venv python, which execs arbitrary tools;
reads/writes `~/.hermes`). Distribute Developer ID + notarized, not Mac App Store.
