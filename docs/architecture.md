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
