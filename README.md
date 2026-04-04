# gateii

A minimal, self-hosted proxy for the Anthropic Claude API.
Runs on any Docker host. No cloud, no signup, no SaaS.

```
Claude Code / your app
        │
        ▼
  gateii :8888   ←── token tracking, caching, rate limiting
        │
        ▼
  api.anthropic.com
```

---

## Why

You're paying for Claude and have no idea what's actually happening.
gateii fixes that.

| Problem | gateii answer |
|---------|---------------|
| No visibility into token usage | Per-user, per-model counters in Redis → Grafana dashboard |
| Sharing one API key is risky | Issue proxy keys via `admin.sh add <user>` |
| Identical prompts waste tokens | SHA-256 exact-match cache (Redis + in-process) |
| Don't want another SaaS | Self-hosted, all state in Redis, no external dependencies |
| Claude Max plan (OAuth) | `passthrough` mode — your token forwarded as-is, no server key |

---

## Quick start

```bash
# 1. Clone and configure
git clone https://github.com/bmmmm/gateii
cd gateii
cp .env.example .env        # edit PASSTHROUGH_USER if you want a name in the dashboard

# 2. Start
docker compose up -d --build

# 3. Tell Claude Code to use it
# Add to ~/.claude/settings.json → env:
#   "ANTHROPIC_BASE_URL": "http://localhost:8888"

# 4. Open dashboard
open http://localhost:3001   # Grafana, no login required
```

That's it. Your existing Anthropic key (or Claude Max OAuth token) flows through unchanged.

---

## Modes

### passthrough — Claude Max plan / own key

No API key stored on the server. gateii forwards whatever the client sends.

```
# .env
PROXY_MODE=passthrough
PASSTHROUGH_USER=alice     # shown in Grafana (optional)
```

Client settings (`~/.claude/settings.json`):
```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:8888"
  }
}
```

Your Anthropic key stays where it is. gateii intercepts, tracks, caches, and forwards.

### apikey — shared team key

gateii holds one Anthropic key. Users get proxy keys from `admin.sh`.

```
# .env
PROXY_MODE=apikey
ANTHROPIC_API_KEY=sk-ant-...
```

```bash
# Issue a proxy key
./scripts/admin.sh add alice
# → sk-proxy-4a7f...  (set as ANTHROPIC_API_KEY in client settings)
```

Client settings:
```json
{
  "env": {
    "ANTHROPIC_API_KEY": "sk-proxy-4a7f...",
    "ANTHROPIC_BASE_URL": "http://your-server:8888"
  }
}
```

---

## Monitoring

Grafana at `http://localhost:3001` — no login, dashboard auto-provisioned.

![Dashboard showing token rate, cache hit rate, latency, and cost panels]

### Metrics

| Metric | Labels | What it tells you |
|--------|--------|-------------------|
| `gateii_tokens_total` | user, model, type | Input/output tokens consumed |
| `gateii_cost_dollars_total` | user, model, type | Estimated cost (Anthropic pricing) |
| `gateii_requests_total` | user, model | Request count |
| `gateii_request_duration_ms_total` | user, model | Cumulative latency (÷ requests = avg) |
| `gateii_upstream_errors_total` | user, model | Non-200 upstream responses |
| `gateii_cache_hits_total` | — | Cache hits |
| `gateii_cache_misses_total` | — | Cache misses |
| `gateii_stop_reason_total` | user, model, reason | end_turn / max_tokens / tool_use |

Prometheus scrape endpoint: `http://localhost:9091/metrics`

---

## Caching

Non-streaming requests are cached by SHA-256 of the full canonical request:

```
provider | model | system | temperature, max_tokens, top_p, top_k,
         stop_sequences, tools, tool_choice | messages
```

Two layers:
1. **L1** — in-process shared dict, 50 MB, max 5 min TTL
2. **L2** — Redis, configurable TTL via `CACHE_TTL` (default 3600 s)

Streaming requests (`"stream": true`) bypass the cache.
Cache hit sets `X-Cache: HIT` response header.

---

## Key management

```bash
./scripts/admin.sh status          # cache stats, key count
./scripts/admin.sh users           # token usage per user
./scripts/admin.sh keys            # all keys, masked
./scripts/admin.sh add alice       # new random proxy key for alice
./scripts/admin.sh revoke sk-proxy-...
./scripts/admin.sh rotate alice    # new key, revoke all old ones
./scripts/admin.sh reset alice     # zero usage counters
```

---

## Stack

| Container | Image | Port | Role |
|-----------|-------|------|------|
| `gateii-proxy` | `openresty/openresty:alpine` | 8888 | nginx + LuaJIT proxy |
| `gateii-redis` | `redis:7-alpine` | — | auth keys, cache, counters |
| `gateii-exporter` | local Python build | 9091 | Prometheus metrics |
| `gateii-prometheus` | `prom/prometheus` | — | metrics storage |
| `gateii-grafana` | `grafana/grafana` | 3001 | dashboard |

All state lives in Redis. No databases, no files to back up (except Redis data volume).

### Vendored Lua libraries

These are included in `config/openresty/lua/resty/` because they're not in the `openresty:alpine` base image:

| Library | Purpose |
|---------|---------|
| `lua-resty-http` | HTTPS upstream requests + streaming |
| `lua-resty-string` | SHA-256 hex encoding for cache keys |

---

## Configuration

All configuration via `.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `PROXY_MODE` | `passthrough` | `passthrough` or `apikey` |
| `PASSTHROUGH_USER` | _(key suffix)_ | Display name in passthrough mode |
| `ANTHROPIC_API_KEY` | — | Required when `PROXY_MODE=apikey` |
| `CACHE_TTL` | `3600` | Cache TTL in seconds |

---

## Adding a provider

1. Create `config/openresty/lua/providers/myprovider.lua`:

```lua
local cjson = require "cjson.safe"
local _M = {}

_M.upstream_url = "https://api.example.com"

function _M.build_headers(upstream_key, auth_type)
    return {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. (upstream_key or ""),
    }
end

-- Returns: input_tokens, output_tokens, stop_reason
function _M.extract_tokens(body)
    local obj = cjson.decode(body)
    if not obj or not obj.usage then return 0, 0, nil end
    return obj.usage.input_tokens or 0, obj.usage.output_tokens or 0, obj.stop_reason
end

return _M
```

2. Register in `config/openresty/lua/providers/init.lua`:

```lua
providers["myprovider"] = require("providers.myprovider")
```

3. Add the env var to `.env` and `docker-compose.yml` if needed, redeploy.

---

## Security notes

| Topic | Status |
|-------|--------|
| `ssl_verify=false` upstream | alpine has no CA bundle — MITM on Anthropic connection possible. Fix: add `ca-certificates` to a custom Dockerfile |
| Redis no password | Network is isolated (bridge); `requirepass` recommended before exposing to untrusted networks |
| Auth cache TTL | Revoked keys work for up to 5 min — reduce in `config/openresty/lua/auth.lua` if needed |
| Request size limit | 10 MB max body (supports vision payloads) — set in `nginx.conf` |

---

## License

[GPL-3.0](LICENSE)
