# gateii — Claude Code Instructions

## Project
Minimal self-hosted Anthropic API proxy. 3 containers: OpenResty (nginx + LuaJIT), Prometheus, Grafana.
No Redis, no external dependencies, no application framework.

## Domain contexts (for agent spawning)
`.claude/domains/` contains per-domain context files — include the relevant file when spawning a
domain-specific agent. Domains: `bench`, `grafana`, `console`, `lua-core`, `omlx`, `infra`.
See `.claude/domains/README.md` for the full map and spawn pattern.

## Local development

The user-facing CLI is `scripts/gateii` (aliased as `gateii` in `~/.zshrc`).
It dispatches to the underlying scripts — prefer it over direct script calls in
user-facing docs.

```bash
# Stack
gateii up                 # start stack (runs GATEII_PREUP_HOOK first if set)
gateii down               # stop containers
gateii reload             # openresty -s reload (no container restart)
gateii logs [service]     # tail logs (default: gateii-proxy)
gateii smoke              # run smoke test
gateii restart [service]  # restart all or one service

# Claude Code routing
gateii switch local-proxy    # through this machine's gateii (checks health first)
gateii switch remote-proxy   # through a remote gateii (needs REMOTE_URL)
gateii switch direct         # bypass proxy, straight to Anthropic
gateii switch status         # show current ANTHROPIC_BASE_URL
gateii sessions              # claudii se — active Claude Code sessions

# Admin / misc
gateii status             # key count, blocked users, current route
gateii admin ...          # passthrough to scripts/admin.sh
gateii rescue             # emergency: switch direct + restart proxy
gateii help               # full subcommand list

# Low-level alternatives (bypass gateii CLI):
#   bash scripts/docker-colima.sh compose up -d   (no hook, no health wait)
#   bash scripts/docker-colima.sh exec gateii-proxy openresty -s reload
```

## Safe dev workflow for proxy changes

When editing Lua or nginx config, switch to direct first so a broken proxy doesn't cut off Claude Code:

```bash
./scripts/admin.sh switch direct         # 1. go direct — Claude Code stays connected
# ... edit Lua/nginx, test changes ...
docker exec gateii-proxy openresty -s reload   # 2. reload to test
./scripts/admin.sh switch local-proxy    # 3. back to proxy when satisfied
```

## Emergency recovery (proxy broken, Claude Code cut off)

```bash
gateii rescue          # switch direct (global+project) + restart proxy container
# then restart Claude Code to reconnect
```

Or from this repo directly:
```bash
./scripts/rescue.sh              # global + project sweep + restart
./scripts/rescue.sh --no-restart # global + project sweep only (if Docker is down too)
./scripts/rescue.sh --no-sweep   # global + restart only (skip project sweep)
```

The project sweep walks `$GATEII_PROJECT_ROOTS` (`:`-separated, PATH-style — so
roots may contain spaces) plus any of `~/offline_coding ~/coding ~/projects
~/dev ~/src` that exist (maxdepth 4); the defaults are always appended. It only
resets `ANTHROPIC_BASE_URL` keys whose host is `localhost`/`127.0.0.1` or that
match the normalized `$REMOTE_URL` from `.env` — non-gateii overrides (e.g.
company proxies) are left alone.

## Gotchas

- **Docker commands:** always use `bash scripts/docker-colima.sh <args>` — auto-sets DOCKER_HOST for Colima, sandbox-safe after Claude Code restart. Never inline `DOCKER_HOST=unix://...` or `DOCKER_CONTEXT=colima docker ...` — those require dangerouslyDisableSandbox
- `ngx.print()` not `ngx.say()` for forwarded response bodies — `ngx.say` adds `\n`, breaks Content-Length
- Shared dict key separator is `|` not `:` — colons break key parsing (sanitize replaces `:|` with `_`)
- Rate limiter only active in `apikey` mode — passthrough has no rate limit
- `.env` is gitignored — never `git add .env`, use `.env.example` for defaults
- Proxy routing order: start stack → switch local-proxy; switch direct → stop stack (never reverse)
- Before editing Lua/nginx: `admin.sh switch direct` first — broken proxy cuts off Claude Code
- `data/keys.json` must use the structured schema (`{user, provider, upstream_key}`); flat `{key: "user"}` format is rejected by `schema.validate_keys` on startup — proxy then runs with empty auth cache (all requests 401)
- `nginx.conf` is a single-file bind mount → every Edit forces a `compose up -d --force-recreate openresty` to be visible in the container. Batch all changes for a feature into ONE Edit. Lua under `config/openresty/lua/` is dir-mounted → no recreate needed
- Console routes: `/console` → 302 → `/console/`; subpages `/console/compare`, `/console/git`, `/console/agents`, `/console/free`; static assets at `/console/static/*` served with explicit MIME types (default `text/plain` trips strict-MIME on .css/.js)

## Key files

| File | Role |
|------|------|
| `config/openresty/lua/auth.lua` | Key validation, passthrough detection, blocking, rate limiting |
| `config/openresty/lua/handler.lua` | Proxy to upstream, SSE token parsing, header forwarding |
| `config/openresty/lua/tracking.lua` | Shared dict counters (tokens, latency, errors, stop_reason) |
| `config/openresty/lua/metrics.lua` | Prometheus exposition format from shared dicts; defensive expired-window guards (emit 0 util when reset_ts in past) |
| `config/openresty/lua/admin_api.lua` | HTTP admin API: block/unblock/limit, /keys, /addkey, /revoke-key (evicts auth_cache cross-worker), /overview, /providers, /llm-prices, /openrouter-models, /health, /git-tracking (GET/PUT), /services/* (proxied to compose-ctl), /agents (live state + bench matrix + omlx /v1/models/status passthrough) |
| `config/openresty/lua/providers/anthropic.lua` | Anthropic header building, token extraction |
| `config/openresty/lua/providers.json` | Multi-provider pricing config, active provider selector |
| `config/openresty/nginx.conf` | Env whitelist, shared dicts, routes, /internal/prometheus proxy, /console/* router, /console/static MIME map |
| `data/keys.json` | Proxy-key → `{user, provider, upstream_key, ...}` mapping (apikey mode, gitignored, structured entries only) |
| `data/git-tracking.json` | Per-repo tracking config: `{default_author, interval, repos:[{path, alias, author, platform}]}` (gitignored) |
| `config/openresty/lua/bootstrap.lua` | HMAC challenge/exchange/confirm handshake for self-provisioning keys |
| `config/openresty/lua/admin_login.lua` | `/internal/admin/login` — session cookie issuance, failure counter |
| `config/openresty/lua/schema.lua` | Startup + admin-API validators for `keys.json`, `limits.json`, `providers.json`, `git-tracking.json` |
| `config/openresty/lua/util.lua` | Shared primitives — currently `atomic_write(path, content)` |
| `config/openresty/lua/circuit_breaker.lua` | Per-upstream breaker for repeated failures |
| `config/openresty/lua/rl_persist.lua` | Persist rate-limit gauges to `data/ratelimit_state.json` (loaded on worker-0 startup, flushed every 30s) — survives container restarts |
| `config/openresty/html/console/{index,compare,git,agents,free}.html` | Five-tab console — Overview / Compare / Git / Agents / Free Models. Shared CSS+JS in `static/` |
| `config/openresty/lua/console_serve.lua` | Routes `/console/`, `/console/compare`, `/console/git`, `/console/agents`, `/console/free` to their HTML files; sets CSP |
| `config/openresty/lua/openrouter_free.lua` | Cached loader for `data/openrouter-free.json` (OpenRouter `:free` pool + default); read by handler.lua per `:free` request |
| `config/openresty/lua/providers/omlx.lua` | Local oMLX provider — Anthropic-format upstream (`/v1/messages`); token extraction sums input+cache_creation+cache_read |
| `scripts/agent` | Wrapper that POSTs simple tasks to gateii→omlx; per-task system prompts + max_tokens; mkdir-lock for max-1 concurrency; writes `data/agents/{active.json,log.jsonl}` |
| `scripts/agent-bench` | Self-adapting benchmark: discovers loaded models, evicts to fit memory budget, runs N trials per (task, model), writes `data/agents/{bench-results.json,bench-report.md,routing.json}` |
| `scripts/statusline-omlx.sh`, `scripts/statusline-compose.sh` | Optional Claude Code statusLine indicator + composer for non-claudii setups (claudii integrates natively via `data/agents/active.json`) |
| `scripts/compose-ctl.py` | Sidecar HTTP control plane — start/stop/restart/recreate any compose service via Console Services panel. Mounts docker socket; whitelisted to services in this compose project |
| `scripts/git-tracking.sh` | Plugin script: reads `data/git-tracking.json` if present (per-repo author + platform), else falls back to filesystem scan. Auto-detects platform from `git remote -v` if not pinned |
| `scripts/proxy-hint.sh` | The reminder itself — `UserPromptSubmit` hook body; warns ≤3×/session when `ANTHROPIC_BASE_URL` is not this gateii. Not wired up by default |
| `scripts/proxy-hook.sh` | Opt-in installer (`gateii hook install/uninstall/status`) — registers/removes `proxy-hint.sh` in `~/.claude/settings.json` via jq (idempotent, atomic). Not global: you wire it in when setting gateii up |

## Architecture decisions

- **No Redis** — all state in nginx shared dicts. Counters don't survive container restarts; Prometheus stores the time series
- **ngx.ctx** passes auth state (user, upstream_key, auth_type) from auth.lua to handler.lua
- **passthrough mode** — client's key forwarded as-is; `ngx.ctx.upstream_auth_type` preserves Bearer vs x-api-key format
- **SSE parsing** — chunks accumulated in memory during streaming, then parsed for `message_start` + `message_delta` events
- **Cost metric** — calculated in metrics.lua (model name → pricing table), not in PromQL
- **Pricing source** — providers.json is source of truth; metrics.lua logs WARN if file missing
- **OR comparison** — console fetches top-10 weekly programming models from OpenRouter (12h cache in counters dict); providers.json comparison_models is static fallback
- **Prometheus retention** — unlimited by default (`HISTORY_RETENTION=` in .env); override with `30d`/`90d`/`180d`/`365d`
- **Blocking** — `blocked|<user>` in shared dict with TTL; daily limits auto-block until midnight UTC
- **Per-key upstream routing** — each `keys.json` entry pins its own `provider` + `upstream_key`; the `x-provider` request header is only a fallback/override, not the primary routing signal
- **Bootstrap handshake** — HMAC-SHA256 challenge/exchange/confirm flow replaces copy-pasting proxy keys; secret disclosed only once on creation, auto-revoke on failed install
- **Admin sessions** — HttpOnly cookie issued by `/internal/admin/login`; console uses it, CLI keeps `X-Admin-Token` header; both accepted on every endpoint
- **Service control** — `gateii-compose-ctl` sidecar holds the docker socket; the proxy reverse-proxies `/internal/admin/services/*` to it under ADMIN_TOKEN. Whitelisted to services in the gateii compose project, actions limited to start/stop/restart/recreate. Self-restart of openresty is async with delay so the request can return first
- **Per-repo git tracking** — `data/git-tracking.json` (managed via `/console/git`) drives the git-tracking sidecar. Each repo can pin its `platform` (forgejo/github/gitlab/…); auto-detected from `git remote get-url origin` if not pinned. Metric label `platform=` lets dashboards group across hosts

## Routing boundary (proxy vs. orchestration)

gateii routes per *request*, by capability — e.g. the OpenRouter free-tier router
(`openrouter_free.lua` + `routes{}`) sends a vision request to a vision model and a
large-context request to a big-context model. That is the proxy's job.

It deliberately does NOT do quality/cost escalation (cheap→expensive model swaps).
A proxy can't judge output quality, and swapping models mid-multi-turn is semantic
chaos. Escalation belongs one layer up, in whatever orchestration drives gateii —
the caller decides the next model per *task*. On free-tier budget exhaustion the
proxy returns a clean 503 + reset time rather than silently downgrading; the caller
decides whether to escalate.

## Providers

Each provider in `config/openresty/lua/providers/` must export:
- `_M.upstream_url` — base URL
- `_M.build_headers(upstream_key, auth_type)` — returns header table
- `_M.extract_tokens(body)` — returns `input_tokens, output_tokens, stop_reason`

Optional fields:
- `_M.extract_tokens_streaming(body)` — for streaming SSE token parsing. If absent, streaming token counts are 0. Returns: `input_tokens, output_tokens, stop_reason, cache_creation, cache_read`
- `_M.stream_options_usage` — optional boolean flag. If `true`, handler.lua injects `stream_options: {include_usage: true}` into the upstream request (needed for OpenAI-format providers to return usage in streaming responses)

## Testing

```bash
curl http://localhost:8888/health
curl http://localhost:8888/metrics | grep gateii_
bash scripts/smoke-test.sh
```

## Admin-API quick-access (`scripts/gctl.sh`)

Helper that reads `ADMIN_TOKEN` from `.env`, logs in once, caches the
session cookie under `/tmp/gctl-session-$UID` (mode 600, 55-min TTL),
and proxies subsequent calls. Saves spelling out `curl + login + cookie`
each time.

```bash
bash scripts/gctl.sh get  '/internal/admin/diagnostics?include=plugins'
bash scripts/gctl.sh post /internal/admin/services/git-tracking/restart
bash scripts/gctl.sh put  /internal/admin/git-tracking '{"interval":300,"repos":[]}'
bash scripts/gctl.sh raw  /metrics                            # no auth, no /internal prefix
```

Allow-listed in `.claude/settings.local.json` so it runs without a
permission prompt; pair Bash calls with `dangerouslyDisableSandbox: true`
because the curl hits localhost (sandbox rule unaffected by the allow-list,
see `feedback_smoke_test_sandbox_bypass.md`).

## Local agents (omlx)

Optional layer for routing simple tasks (commit messages, summaries, doc
comments, structured extractions, …) to a local Apple-Silicon LLM instead
of burning Claude API tokens on them.

**Install omlx** (one-time, host-side):
```bash
brew tap jundot/omlx https://github.com/jundot/omlx
brew install omlx
omlx serve --model-dir ~/.omlx/models    # or via the desktop app
# Admin web-UI: http://localhost:8000/admin   (download / load / unload models)
# OpenAPI:      http://localhost:8000/openapi.json
```

omlx exposes both the OpenAI (`/v1/chat/completions`) and Anthropic
(`/v1/messages`) APIs. gateii routes through the Anthropic path, so the
provider patch in `config/openresty/lua/providers/omlx.lua` reuses
`anthropic.extract_tokens`. The oMLX usage quirk: real input lands in
`cache_creation_input_tokens` (with `input_tokens=0`); the lua sums all
three input fields.

**Use the wrapper:**
```bash
echo "<input>" | scripts/agent run <task>
scripts/agent tasks                   # list available tasks
scripts/agent list                    # currently running + last 10 records
```

Tasks: `commit-msg summarize-file classify-yesno rename doc-comment
extract-json explain-line refactor-suggestion ambiguity-check unix-recipe
code-gen-short`. Each pins its own system prompt + max_tokens cap. Lock is
mkdir-based (`data/agents/lock.d`), max 1 concurrent agent.

**Bench-driven model picker:**
```bash
scripts/agent-bench                   # default: full suite on Qwen3.5-9B
                                       # + small models, comparison-only on big
                                       # + claude-haiku reference if claude CLI on PATH
scripts/agent-bench --quick           # 1 trial, default model only (no reference)
scripts/agent-bench --task TASK       # single task, all models
scripts/agent-bench --no-reference    # skip Haiku even if claude CLI available
scripts/agent-bench --reference-model claude-haiku-4-5-20251001  # override reference
```

Writes `data/agents/{bench-results.json, bench-report.md, routing.json}`.
The wrapper consults `routing.json` and switches *away* from the default
model only on a *qualitative* win (default fails, candidate passes 100%) —
ignores marginal latency advantages so we don't burn 15-21 GB of RAM for
an 80 ms saving.

Reference model (Haiku) appears in the bench matrix for quality comparison
but is never written into routing.json — excluded from local routing decisions.
Uses `claude --print` with the existing Claude Code auth (no separate API key).
Smart-skip: re-runs reference only once per day (or with --force).

**Visualization:** Console tab at `http://localhost:8888/console/agents`
shows live active agent, recent runs (full log.jsonl tail), per-model
**load state + lifetime usage stats** (calls oMLX's `/v1/models/status`
on every poll, aggregates log.jsonl by model for runs / avg-latency /
pass-rate / last-used), per-model **load/unload buttons** + an
**Unload all** button, and the full bench matrix (task × model heatmap).
The footer's "diagnostics" link surfaces `?include=agents` from
`/internal/admin/diagnostics` (omlx connectivity, file sizes, bench
freshness, smart-skip log).

**Permanent history:** `metrics.lua` re-emits the latest `bench-results
.json` + `routing.json` as Prometheus gauges (`gateii_omlx_bench_pass
_rate{task,model}`, `gateii_omlx_bench_latency_seconds{...}`, `gateii
_omlx_routing_choice{task,model}`, `gateii_omlx_model_created_timestamp
_seconds{model}`) so Grafana keeps the time series long after the JSON
file is overwritten.

**Smart-skip rebench:** `scripts/agent-bench` is `--smart` by default —
skips models whose previous results exist AND whose omlx-registration
`created` timestamp is unchanged. Use `--force` to re-run from scratch
(e.g. after omlx upgrade), `--quick` for a 1-trial smoke test on the
default model, `--task X` for one task across all models.

**API extensions** (under `/internal/admin/`):
- `GET  /agents`           — `{active, recent, routing, bench, usage, omlx_status}`
- `POST /models`           — body `{action:"load|unload",model:"<id>"}`,
                              proxies to omlx `/v1/models/<id>/(load|unload)`
- `GET  /diagnostics?include=agents` — see "Visualization" above

**Statusline integration:** the data file `data/agents/active.json` is
the source of truth for "what's running right now". Display logic lives
in `~/offline_coding/claudii` — run `claudii omlx connect` once to wire
it up. `scripts/statusline-omlx.sh` + `scripts/statusline-compose.sh`
are kept as fallbacks for non-claudii setups.

## Do not
- Read or commit `.env` (contains API keys)
- Change `ssl_verify` to true without adding CA certs to the image
- Stop the proxy before running `admin.sh switch direct` (loses Claude Code connection)

## oMLX Routing — Claude-Side Guide

When to delegate to `scripts/agent` instead of handling myself:

| Task | Trigger |
|------|---------|
| `commit-msg` | summarizing `git diff` for a commit message |
| `summarize-file` | "what does this file do in one sentence?" (≤2k tokens input) |
| `classify-yesno` | binary decision question with short justification |
| `rename` | "better name for `<var>`?" |
| `doc-comment` | one-line docstring for a small function |
| `extract-json` | pulling structured fields from unstructured text |
| `explain-line` | "what does this line do?" — single-line answer |
| `refactor-suggestion` | one concrete refactor proposal for a snippet |
| `ambiguity-check` | is a user request unambiguous enough? |
| `unix-recipe` | "how do I solve X with shell commands?" — 3 suggestions |
| `code-gen-short` | short function (~20 lines) from spec |

**Do NOT delegate:** multi-step reasoning, math, architecture decisions, code > 250 tokens output, tasks needing tools (Read/Edit/Bash), format-critical output.

**Fallback:** if `scripts/agent` exits non-zero or output is clearly bad (too long, wrong format, empty, `AMBIGUOUS:` prefix) — generate myself, silently.

**Feedback** (run immediately after each call):
```bash
scripts/agent feedback <task> used              # output used as-is
scripts/agent feedback <task> improved format   # minor formatting fix
scripts/agent feedback <task> improved content  # minor content fix
scripts/agent feedback <task> replaced format   # discarded: wrong format
scripts/agent feedback <task> replaced content  # discarded: wrong content
scripts/agent feedback <task> replaced capability # discarded: model can't do this
scripts/agent feedback <task> replaced length   # discarded: too long/short
```
