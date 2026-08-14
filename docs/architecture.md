# Architecture

## Three containers

| Container | Image | Port | Role |
|-----------|-------|------|------|
| `gateii-proxy` | `openresty/openresty:alpine` | 8888 | nginx + LuaJIT proxy + metrics |
| `gateii-prometheus` | `prom/prometheus` | 9090 | metrics storage |
| `gateii-grafana` | `grafana/grafana` | 3001 | dashboard |
| `gateii-git-tracking` | `alpine` _(plugin)_ | — | git activity metrics (optional) |

All runtime state lives in nginx shared memory. Prometheus stores the time
series — the proxy itself is effectively stateless between restarts.

## Why no Redis

Early versions used Redis for response caching, auth key storage, and
metrics counters. Removed because:

- **Cache was useless.** Claude Code sends `stream: true` on every
  request — streaming bypasses the cache. Zero hits in practice.
- **Shared dicts are faster.** nginx shared memory has no network hop, no
  serialization overhead. Counters survive worker restarts.
- **Fewer moving parts.** 3 containers instead of 5. No Redis tuning, no
  persistence config, no connection pool management.
- **Prometheus is the real store.** Counter values in shared dicts don't
  need to survive container restarts — Prometheus already has the time
  series.

## Request flow

```
Claude Code
     │
     │  POST /v1/messages
     ▼
┌────────────────────────────────────┐
│ gateii-proxy (openresty)           │
│                                    │
│  nginx.conf    → routes            │
│  auth.lua      → validate key      │
│  handler.lua   → proxy + SSE parse │
│  tracking.lua  → counters          │
│  metrics.lua   → /metrics endpoint │
└────────────────────────────────────┘
     │
     │  forward (headers rebuilt)
     ▼
api.anthropic.com
     │
     │  SSE stream
     ▼
[handler.lua buffers + parses usage]
     │
     ▼
Claude Code (streaming response)
```

## Key files

| File | Role |
|------|------|
| `config/openresty/lua/auth.lua` | Key validation, passthrough detection, blocking, rate limiting |
| `config/openresty/lua/handler.lua` | Proxy to upstream, SSE token parsing, header forwarding |
| `config/openresty/lua/tracking.lua` | Shared-dict counters (tokens, latency, errors, stop_reason) |
| `config/openresty/lua/metrics.lua` | Prometheus exposition from shared dicts |
| `config/openresty/lua/admin_api.lua` | HTTP admin API (block/unblock/limit, /providers, /llm-prices, /openrouter-models) |
| `config/openresty/lua/providers/anthropic.lua` | Anthropic header building, token extraction |
| `config/openresty/lua/providers.json` | Multi-provider pricing config, active provider selector |
| `config/openresty/nginx.conf` | Env whitelist, shared dicts, routes, `/internal/prometheus` proxy |
| `data/keys.json` | Proxy-key → `{user, provider, upstream_key, …}` mapping (apikey mode) |
| `config/openresty/lua/bootstrap.lua` | HMAC challenge/exchange/confirm handshake for self-provisioning keys |
| `config/openresty/lua/admin_login.lua` | `/internal/admin/login` — session cookie issuance, failure counter |
| `config/openresty/lua/schema.lua` | Startup validation for `keys.json` and `limits.json` |
| `config/openresty/lua/circuit_breaker.lua` | Per-upstream breaker for repeated failures |

Full component map including scripts, console assets, and the free-tier and
oMLX modules: [key-files.md](key-files.md).

## Design decisions

### `ngx.ctx` for request-scoped auth state

`auth.lua` stores the authenticated user, upstream key, and auth type in
`ngx.ctx`. `handler.lua` reads them back. This keeps the phases cleanly
separated — auth decides, handler acts.

### Passthrough mode preserves auth format

In passthrough mode, `ngx.ctx.upstream_auth_type` tracks whether the
client sent `Bearer <token>` (OAuth) or `x-api-key: <key>` so the upstream
receives the same format. OAuth tokens mis-sent as API keys would fail.

### SSE parsing is buffered, not streaming

Chunks accumulate in memory during streaming, then `message_start` and
`message_delta` events are parsed at the end. Reasons:

- Anthropic's streaming format emits `usage` across two events —
  single-pass parsing doesn't work.
- Typical response sizes are < 1 MB, well within nginx worker memory.
- Simpler than tracking incremental parse state.

For very long responses (> 10 MB), the `client_max_body_size` limit in
`nginx.conf` would kick in first. Not observed in practice.

### Cost calculated in `metrics.lua`, not PromQL

Pricing lives in `providers.json` and applied during metric export. Means:

- Cost rows in Prometheus have absolute values, not label-encoded rates.
- Changing prices requires a `gateii reload`, not a Grafana refresh.
- Grafana queries stay simple (no `label_join` gymnastics).

### Blocking via shared dict

`blocked|<user>` entries in a shared dict, with TTL. Daily limits
auto-block until midnight UTC by setting the TTL. Key separator is `|`
(not `:`) because colons appear in user names — `sanitize()` in `auth.lua`
replaces `:|` with `_`.

### Per-upstream circuit breaker

`circuit_breaker.lua` tracks consecutive failures per upstream URL. After
N failures, opens the breaker for a cooldown period — requests to that
upstream fail fast with 503 instead of waiting for timeout. Closes
automatically on cooldown expiry.

### `providers.json` is the pricing source of truth

`metrics.lua` reads it at export time and logs a WARN if the file is
missing — cost metrics silently reading zeroes would be worse than a noisy
log line. Details: [monitoring.md](monitoring.md#how-cost-is-calculated).

### OpenRouter comparison list is fetched, not pinned

The console fetches the top-10 weekly programming models from OpenRouter and
caches them for 12 h in the `counters` dict. `comparison_models` in
`providers.json` is the static fallback when the fetch fails.

### Per-key upstream routing beats the `x-provider` header

Each `keys.json` entry pins its own `provider` + `upstream_key`; the
`x-provider` request header is only a fallback/override, never the primary
routing signal. See [keys.md](keys.md#per-key-upstream-routing).

### Rate-limit state is persisted, counters are not

`rl_persist.lua` flushes rate-limit gauges to `data/ratelimit_state.json`
every 30 s and reloads them on worker-0 startup, so a container restart
doesn't hand every blocked user a fresh budget. Plain request/token counters
deliberately stay volatile — Prometheus is their store.

### openresty runs unprivileged (uid 65534)

Since `47a4f09` the proxy drops to uid 65534 (nobody). Consequence: every tmpfs
mount it writes to needs an explicit `:mode=1777` in the compose file — the
default tmpfs mode is 755/root, which the unprivileged worker cannot write.

There are six temp dirs, and missing the mode on one of them fails in a way
that looks like anything but a permissions bug: small POSTs and GETs work
fine, `/health` and `/metrics` stay green, but a POST whose body spills to
`client_body_temp` (i.e. exceeds `client_body_buffer_size`) returns 500. In
practice that reads as "Claude Code sessions randomly break on large messages"
— vision payloads, long histories — while every health check says the proxy is
fine.

### Service control lives in a sidecar, not the proxy

`gateii-compose-ctl` holds the docker socket; the proxy reverse-proxies
`/internal/admin/services/*` to it under `ADMIN_TOKEN`. The sidecar is
whitelisted to services in the gateii compose project and actions are limited
to start/stop/restart/recreate. Self-restart of openresty is async with a
delay so the request can return first.

### Per-repo git tracking carries a `platform` label

`data/git-tracking.json` (managed via `/console/git`) drives the git-tracking
sidecar. Each repo can pin its `platform` (forgejo/github/gitlab/…), which is
auto-detected from `git remote get-url origin` when not pinned. The metric
label `platform=` lets dashboards group across hosts. See
[plugins.md](plugins.md#git-tracking).

## Routing boundary (proxy vs. orchestration)

gateii routes per *request*, by capability — the OpenRouter free-tier router
(`openrouter_free.lua` + handler `routes{}`) sends a vision request to a
vision model and a large-context request to a big-context model.

It deliberately does **not** do quality/cost escalation (cheap→expensive model
swaps). A proxy cannot judge output quality, and swapping models mid-multi-turn
is semantic chaos. Escalation belongs one layer up, in whatever orchestration
drives gateii — the caller decides the next model per *task*. On free-tier
budget exhaustion the proxy returns a clean 503 + reset time rather than
silently downgrading; the caller decides whether to escalate.

This boundary is cited from `handler.lua` and `openrouter_free.lua` as
"CLAUDE.md § Routing boundary"; `CLAUDE.md` keeps the rule, this section keeps
the rationale.

## Admin surface

Two authentication paths into `/internal/admin/*`:

1. **Session cookie** — `POST /internal/admin/login` with `{token}` sets
   `admin_session=<hex>; HttpOnly; SameSite=Strict` (1 h TTL; `Secure` added
   when served over HTTPS). Used by the `/console` web UI.
2. **Header** — `X-Admin-Token: <ADMIN_TOKEN>`. Used by
   `scripts/admin.sh` and ad-hoc curl.

Both accepted on every endpoint. In `apikey` mode a missing `ADMIN_TOKEN`
fail-closes the admin API with 503. In `passthrough` mode the admin API
stays open behind the IP allow-list (no server-side secrets to protect).

Full endpoint reference: [admin-api.md](admin-api.md). Security posture:
[security.md](security.md).
