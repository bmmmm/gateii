# Key files — component map

Canonical inventory of the files that carry behaviour. Read this before
touching a subsystem you haven't worked in; `CLAUDE.md` keeps the same list
with one-line roles for quick orientation.

## Lua modules (`config/openresty/lua/`)

| File | Role |
|------|------|
| `auth.lua` | Key validation, passthrough detection, blocking, rate limiting. `sanitize()` replaces `:|` with `_` because the shared-dict key separator is `|` |
| `handler.lua` | Proxy to upstream, SSE token parsing, header forwarding. Injects `stream_options: {include_usage: true}` for providers that set `stream_options_usage` |
| `tracking.lua` | Shared dict counters (tokens, latency, errors, stop_reason) |
| `metrics.lua` | Prometheus exposition format from shared dicts; defensive expired-window guards (emit 0 util when `reset_ts` is in the past). Also re-emits the latest `bench-results.json` + `routing.json` as `gateii_omlx_*` gauges |
| `admin_api.lua` | HTTP admin API: block/unblock/limit, `/keys`, `/addkey`, `/revoke-key` (evicts `auth_cache` cross-worker), `/overview`, `/providers`, `/llm-prices`, `/openrouter-models`, `/health`, `/git-tracking` (GET/PUT), `/services/*` (proxied to compose-ctl), `/agents` (live state + bench matrix + omlx `/v1/models/status` passthrough) |
| `admin_login.lua` | `/internal/admin/login` — session cookie issuance, failure counter |
| `bootstrap.lua` | HMAC challenge/exchange/confirm handshake for self-provisioning keys. Requires the `bit` module (LuaJIT has it built in; PUC lua5.1 in CI needs `lua5.1-bitop`) |
| `schema.lua` | Startup + admin-API validators for `keys.json`, `limits.json`, `providers.json`, `git-tracking.json` |
| `util.lua` | Shared primitives — currently `atomic_write(path, content)` |
| `circuit_breaker.lua` | Per-upstream breaker for repeated failures |
| `rl_persist.lua` | Persists rate-limit gauges to `data/ratelimit_state.json` (loaded on worker-0 startup, flushed every 30 s) — survives container restarts |
| `console_serve.lua` | Routes `/console/`, `/console/compare`, `/console/git`, `/console/agents`, `/console/free` to their HTML files; sets CSP |
| `openrouter_free.lua` | Cached loader for `data/openrouter-free.json` (OpenRouter `:free` pool + default) plus free-tier budget bookkeeping: per-window request counting, 429-armed exhaustion signal (drives handler's 503), budget snapshot for `/metrics` + admin GET. `fallback_models()` builds the injected `models` array — skipped when the client sends `x-gateii-no-fallback` (pinned-model evals) |
| `providers/anthropic.lua` | Anthropic header building, token extraction |
| `providers/omlx.lua` | Local oMLX provider — Anthropic-format upstream (`/v1/messages`); token extraction sums `input` + `cache_creation` + `cache_read` |

## Config and data

| File | Role |
|------|------|
| `config/openresty/nginx.conf` | Env whitelist, shared dicts, routes, `/internal/prometheus` proxy, `/console/*` router, `/console/static` MIME map. Single-file bind mount — every edit needs `compose up -d --force-recreate openresty` |
| `config/openresty/lua/providers.json` | Multi-provider pricing config, active provider selector |
| `config/openresty/html/console/{index,compare,git,agents,free}.html` | Five-tab console — Overview / Compare / Git / Agents / Free Models. Shared CSS + JS in `static/` |
| `data/keys.json` | Proxy-key → `{user, provider, upstream_key, …}` mapping (apikey mode, gitignored, structured entries only — see [keys.md](keys.md)) |
| `data/git-tracking.json` | Per-repo tracking config: `{default_author, interval, repos:[{path, alias, author, platform}]}` (gitignored) |

## Scripts

| File | Role |
|------|------|
| `scripts/gateii` | User-facing CLI — dispatches to the scripts below. See [cli.md](cli.md) |
| `scripts/admin.sh` | Admin CLI (keys, blocking, limits, `switch`) |
| `scripts/gctl.sh` | Admin-API quick-access — reads `ADMIN_TOKEN` from `.env`, logs in once, caches the session cookie under `/tmp/gctl-session-$UID` (mode 600, 55-min TTL), proxies subsequent calls |
| `scripts/rescue.sh` | Emergency recovery — global + project `ANTHROPIC_BASE_URL` sweep + proxy restart. See [routing.md](routing.md#emergency-rescue) |
| `scripts/docker-colima.sh` | Docker wrapper that sets `DOCKER_HOST` for Colima — always use it instead of raw `docker` |
| `scripts/deploy-nutc.sh` | Production deploy: rsync compose + config to nutc `~/docker/gateii`, seed `.env` once, `up -d --force-recreate openresty` (proxy only), health-poll. `NUTC_SERVER_HOST=100.64.0.2` when off-LAN (Tailscale) |
| `scripts/smoke-test.sh` | Smoke test (`gateii smoke`) |
| `scripts/agent` | Wrapper that POSTs simple tasks to gateii→omlx; per-task system prompts + `max_tokens`; mkdir-lock for max-1 concurrency; writes `data/agents/{active.json,log.jsonl}` |
| `scripts/agent-bench` | Self-adapting benchmark: discovers loaded models, evicts to fit the memory budget, runs N trials per (task, model), writes `data/agents/{bench-results.json,bench-report.md,routing.json}` |
| `scripts/statusline-omlx.sh`, `scripts/statusline-compose.sh` | Optional Claude Code `statusLine` indicator + composer for non-claudii setups (claudii integrates natively via `data/agents/active.json`) |
| `scripts/compose-ctl.py` | Sidecar HTTP control plane — start/stop/restart/recreate any compose service via the Console Services panel. Mounts the docker socket; whitelisted to services in this compose project |
| `scripts/git-tracking.sh` | Plugin script: reads `data/git-tracking.json` if present (per-repo author + platform), else falls back to a filesystem scan. Auto-detects platform from `git remote -v` if not pinned |
| `scripts/proxy-hint.sh` | The reminder itself — `UserPromptSubmit` hook body; warns ≤3×/session when `ANTHROPIC_BASE_URL` is not this gateii. Not wired up by default |
| `scripts/proxy-hook.sh` | Opt-in installer (`gateii hook install/uninstall/status`) — registers/removes `proxy-hint.sh` in `~/.claude/settings.json` via jq (idempotent, atomic). Not global: you wire it in when setting gateii up |

## Related

- [architecture.md](architecture.md) — request flow and design decisions
- [testing.md](testing.md) — smoke test and local CI parity
- [agents.md](agents.md) — the oMLX layer in full
