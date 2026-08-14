# gateii — Claude Code Instructions

## Project
Minimal self-hosted Anthropic API proxy. 3 containers: OpenResty (nginx + LuaJIT), Prometheus, Grafana.
No Redis, no external deps, no application framework.

**Production runs on nutc** (since 2026-07-17) under `~/docker/gateii`, at
`http://100.64.0.2:8888` (Tailscale). Deploy with `scripts/deploy-nutc.sh`
(rsyncs compose + config, force-recreates the proxy only; server-owned
`.env`/`data/` are never overwritten). The stack came up manually during the
move, so **prometheus + grafana also run on nutc**
(verified 2026-07-22), a metric-history stopgap until garage's scrape job
for `nutc:8888/metrics` lands (TODO). End-state: openresty-only + garage
scrapes. (compose-ctl came up too but crash-loops; its source is never deployed
to nutc — remove it: `docker rm -f gateii-compose-ctl`.)

The local Colima stack is dev-only — don't leave it running: two gateii
instances = two drifting estimates of the account-wide OpenRouter budget.

## Docs map — read before touching a subsystem

- `docs/key-files.md` — any module: the full component map
- `docs/architecture.md` — request flow, pricing, any design decision
- `docs/agents.md` — anything oMLX: wrapper, bench, console tab, metrics
- `docs/testing.md` — running or changing the suites / CI
- `docs/routing.md` — switch/rescue behaviour, the project sweep
- `docs/providers.md` — adding or changing a provider
- `docs/admin-api.md` — any `/internal/admin/*` endpoint, plus `gctl.sh`
- `docs/cli.md` — changing `scripts/gateii` subcommands
- also: `keys.md`, `security.md`, `monitoring.md`, `configuration.md`,
  `bootstrap.md`, `plugins.md`, `modes.md`, `getting-started.md`

`.claude/domains/` holds per-domain context files for agent spawning — `bench`,
`grafana`, `console`, `lua-core`, `omlx`, `infra`. Include the relevant one when
spawning a domain agent; see `.claude/domains/README.md`.

## Local development

`scripts/gateii` (aliased `gateii` in `~/.zshrc`) dispatches to the underlying
scripts — prefer it over direct script calls in user-facing docs. Reference:
`docs/cli.md`, `gateii help`.

```bash
gateii up | down | reload | restart [svc] | logs [svc] | smoke
gateii switch local-proxy | remote-proxy | direct | status
gateii sessions   # claudii se — active Claude Code sessions
gateii status     # key count, blocked users, current route
gateii admin ...  # passthrough to scripts/admin.sh
gateii rescue     # emergency: switch direct + restart proxy
```

Bypassing the CLI skips the preup hook and health wait:
`bash scripts/docker-colima.sh compose up -d`.

**Safe dev workflow for proxy changes:** `switch direct` → edit Lua/nginx →
`gateii reload` → `switch local-proxy`. Direct first keeps Claude Code connected
if the edit breaks the proxy. Rationale + emergency path: `docs/routing.md`.

## Gotchas

- **Docker:** always `bash scripts/docker-colima.sh <args>` — sets DOCKER_HOST for Colima, sandbox-safe. Never inline `DOCKER_HOST=unix://...` or `DOCKER_CONTEXT=colima docker ...` (those need dangerouslyDisableSandbox)
- `ngx.print()` not `ngx.say()` for forwarded response bodies — `ngx.say` adds `\n`, breaks Content-Length
- Shared dict key separator is `|` not `:` — colons break key parsing (sanitize replaces `:|` with `_`)
- Rate limiter only active in `apikey` mode — passthrough has no rate limit
- `.env` is gitignored — never `git add .env`, use `.env.example` for defaults
- Proxy routing order: start stack → switch local-proxy; switch direct → stop stack (never reverse)
- `data/keys.json` needs the structured schema (`{user, provider, upstream_key}`); flat `{key: "user"}` is rejected by `schema.validate_keys` on startup — the proxy then runs with an empty auth cache (all requests 401)
- `nginx.conf` is a single-file bind mount → every Edit needs `compose up -d --force-recreate openresty` to take effect, so batch a feature's changes into ONE Edit. Lua under `config/openresty/lua/` is dir-mounted → no recreate
- Console routes: `/console` → 302 → `/console/`; subpages `/console/{compare,git,agents,free}`. Assets at `/console/static/*` need explicit MIME types (default `text/plain` trips strict-MIME on .css/.js)
- `resolver 127.0.0.11 valid=30s ipv6=off;` in nginx.conf is required — Lua cosockets do NOT use the system resolver
- `localhost` ≠ `127.0.0.1` on Alpine (IPv6 preferred) — always use `127.0.0.1` in health checks
- lua-resty-http 0.16+ requires BOTH `http.lua` AND `http_connect.lua` in `resty/`
- `ssl_verify=false` is intentional (Alpine has no CA bundle) — do not "fix" without adding ca-certificates to the image
- openresty runs as uid 65534 (non-root, since `47a4f09`) — every tmpfs it writes to needs an explicit `:mode=1777`. Miss it on one of the six temp dirs and a POST spilling to `client_body_temp` (over `client_body_buffer_size`) 500s while `/health`/`/metrics` stay green; symptom write-up in `docs/architecture.md`

## Key files

Complete inventory; full descriptions in `docs/key-files.md`.

Lua, under `config/openresty/lua/`:

- `auth.lua` — key validation, passthrough, blocking, rate limiting
- `handler.lua` — upstream proxy, SSE token parsing, header forwarding
- `tracking.lua` — shared dict counters (tokens, latency, errors, stop_reason)
- `metrics.lua` — Prometheus exposition; expired-window guards
- `admin_api.lua` — admin HTTP API: keys, blocking, `/services/*`, `/agents`
- `admin_login.lua` — `/internal/admin/login`, session cookie, failure counter
- `bootstrap.lua` — HMAC challenge/exchange/confirm handshake
- `schema.lua` — validators for `keys.json`, `limits.json`, `providers.json`, `git-tracking.json`
- `util.lua` — shared primitives, currently `atomic_write(path, content)`
- `circuit_breaker.lua` — per-upstream breaker for repeated failures
- `rl_persist.lua` — rate-limit gauges → `data/ratelimit_state.json`
- `console_serve.lua` — `/console/*` page routing, sets CSP
- `openrouter_free.lua` — OpenRouter `:free` pool + free-tier budget bookkeeping
- `providers/anthropic.lua` — Anthropic headers, token extraction
- `providers/omlx.lua` — local oMLX provider, Anthropic-format upstream

Config and data:

- `config/openresty/nginx.conf` — env whitelist, shared dicts, routes, MIME map
- `config/openresty/lua/providers.json` — pricing config, active provider
- `config/openresty/html/console/{index,compare,git,agents,free}.html` — five-tab console, CSS+JS in `static/`
- `data/keys.json` — proxy-key → `{user, provider, upstream_key, ...}` (gitignored)
- `data/git-tracking.json` — per-repo tracking config (gitignored)

Scripts:

- `scripts/agent` — oMLX task wrapper, mkdir-lock, `data/agents/{active.json,log.jsonl}`
- `scripts/agent-bench` — benchmark → `data/agents/{bench-results.json,bench-report.md,routing.json}`
- `scripts/statusline-omlx.sh`, `scripts/statusline-compose.sh` — statusLine fallbacks (non-claudii)
- `scripts/compose-ctl.py` — compose-service sidecar, holds the docker socket
- `scripts/git-tracking.sh` — plugin: per-repo author + platform, else filesystem scan
- `scripts/proxy-hint.sh` — `UserPromptSubmit` hook body, warns on a wrong `ANTHROPIC_BASE_URL`
- `scripts/proxy-hook.sh` — opt-in installer, `gateii hook install/uninstall/status`
- `scripts/deploy-nutc.sh` — deploy to nutc, `NUTC_SERVER_HOST=100.64.0.2` off-LAN

## Architecture decisions

Rationale in `docs/architecture.md`. Load-bearing invariants:

- **No Redis** — state in nginx shared dicts; Prometheus is the time-series store
- **ngx.ctx** passes auth state (user, upstream_key, auth_type) auth.lua → handler.lua
- **SSE parsing** buffers chunks, then parses `message_start` + `message_delta`
- **Cost** computed in metrics.lua from `providers.json`, never in PromQL
- **Per-key upstream routing** wins over the `x-provider` header (fallback only)
- **Admin auth** — HttpOnly session cookie *or* `X-Admin-Token`, both accepted everywhere
- **Blocking** — `blocked|<user>` in a shared dict with TTL; daily limits auto-block until midnight UTC

## Routing boundary (proxy vs. orchestration)

Anchor cited from `handler.lua` + `openrouter_free.lua`; keep this heading.

gateii routes per *request*, by capability (`openrouter_free.lua` + `routes{}`:
vision request → vision model, large-context → big-context model). It
deliberately does NOT do quality/cost escalation — a proxy can't judge output
quality, and swapping models mid-multi-turn is semantic chaos. Escalation
belongs one layer up: the caller decides the next model per *task*. On free-tier
exhaustion the proxy returns a clean 503 + reset time instead of silently
downgrading. Rationale: `docs/architecture.md`.

## Sibling project (futurenotsub)

`~/offline_coding/futurenotsub` ("future, not subscription", private Forgejo
origin) shares gateii's goal: flip off the Claude Max subscription within a day.
It is the **measurement + tier-routing brain** — eval suite (real task fixtures,
N=3, pass/fail); its `routing.json` owns the tier-alias contract
(`worker-local/-small/-mid/-big`) + per-class ladders and names gateii as an
eventual consumer. gateii stays the **per-request router**. Not started:
OpenRouter `:free` as a measured `worker-free` tier data-driving `routes{}` via
`FNS_BASE_URL`→gateii→openrouter.

## Providers

Every module in `config/openresty/lua/providers/` must export `_M.upstream_url`,
`_M.build_headers(upstream_key, auth_type)` and `_M.extract_tokens(body)` →
`input_tokens, output_tokens, stop_reason`. Optional:
`_M.extract_tokens_streaming(body)` (absent → streaming counts are 0) and
`_M.stream_options_usage`. Full contract: `docs/providers.md`.

## Testing

```bash
curl http://localhost:8888/health
curl http://localhost:8888/metrics | grep gateii_
bash scripts/smoke-test.sh
```

Full suite: 73 `busted` tests + `spec/admin_sh_test.sh` (29-test bash suite, run
separately), both in CI. Running luacheck/busted locally has real traps (Alpine
not Ubuntu, `lua5.1-bitop`, versioned binaries) — read `docs/testing.md` first.

## Admin-API quick-access (`scripts/gctl.sh`)

Reads `ADMIN_TOKEN` from `.env`, logs in once, caches the session cookie. Use it
instead of hand-rolling curl + login + cookie:

```bash
bash scripts/gctl.sh get  '/internal/admin/diagnostics?include=plugins'
bash scripts/gctl.sh post /internal/admin/services/git-tracking/restart
bash scripts/gctl.sh put  /internal/admin/git-tracking '{"interval":300,"repos":[]}'
bash scripts/gctl.sh raw  /metrics          # no auth, no /internal prefix
```

Allow-listed in `.claude/settings.local.json`, but still pair Bash calls with
`dangerouslyDisableSandbox: true` — the curl hits localhost
(`feedback_smoke_test_sandbox_bypass.md`). Details: `docs/admin-api.md`.

## Local agents (omlx)

Optional layer routing simple tasks to a local Apple-Silicon LLM instead of
Claude API tokens. Wrapper `scripts/agent run <task>`, benchmark
`scripts/agent-bench`, console tab `/console/agents`, permanent history via
`gateii_omlx_*` Prometheus gauges. Read **`docs/agents.md`** before changing
anything here — install, tasks, bench flags, admin endpoints, limitations.

## Do not
- Read or commit `.env` (API keys)
- Set `ssl_verify=true` without CA certs in the image
- Stop the proxy before `admin.sh switch direct` (kills the Claude Code connection)

## oMLX Routing — Claude-Side Guide

Delegate to `scripts/agent run <task>` instead of doing it myself for:
`commit-msg` (summarize a `git diff`), `summarize-file` (≤2k tokens input),
`classify-yesno`, `rename`, `doc-comment`, `extract-json`, `explain-line`,
`refactor-suggestion`, `ambiguity-check`, `unix-recipe`, `code-gen-short`.
Per-task triggers + newer tasks: `docs/agents.md`.

**Do NOT delegate:** multi-step reasoning, math, architecture decisions, code > 250 tokens output, tasks needing tools (Read/Edit/Bash), format-critical output.

**Fallback:** `scripts/agent` non-zero or output clearly bad (too long, wrong format, empty, `AMBIGUOUS:` prefix) — generate myself, silently.

**Feedback**, immediately after each call: `scripts/agent feedback <task> used` ·
`improved format|content` · `replaced format|content|capability|length`.
