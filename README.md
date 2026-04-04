# gateii

A minimal, self-hosted proxy for the Anthropic Claude API.
Runs on any Docker host. No cloud, no signup, no SaaS.

```
Claude Code / your app
        |
        v
  gateii :8888   <-- token tracking, rate limiting, monitoring
        |
        v
  api.anthropic.com
```

---

## Why

You're paying for Claude and have no idea what's actually happening.
gateii fixes that.

| Problem | gateii answer |
|---------|---------------|
| No visibility into token usage | Per-user, per-model counters in Grafana dashboard |
| Sharing one API key is risky | Issue proxy keys via `admin.sh add <user>` |
| Don't want another SaaS | Self-hosted, stateless proxy, no external dependencies |
| Claude Max plan (OAuth) | `passthrough` mode -- your token forwarded as-is, no server key |

### Why no Redis?

Early versions used Redis for response caching, auth key storage, and metrics
counters. We removed it because:

- **Cache was useless**: Claude Code sends `stream: true` on every request --
  streaming bypasses the cache. Zero hits in practice.
- **Shared dicts are faster**: nginx shared memory has no network hop, no
  serialization overhead. Counters survive worker restarts.
- **Less moving parts**: 3 containers instead of 5. No Redis tuning, no
  persistence config, no connection pool management.
- **Prometheus is the real store**: Counter values in shared dicts don't need
  to survive container restarts -- Prometheus already has the time series.

---

## Quick start

```bash
# 1. Clone and configure
git clone https://github.com/bmmmm/gateii
cd gateii
cp .env.example .env        # edit PASSTHROUGH_USER if you want a name in the dashboard

# 2. Start
docker compose up -d

# 3. Tell Claude Code to use it
# Add to ~/.claude/settings.json -> env:
#   "ANTHROPIC_BASE_URL": "http://localhost:8888"

# 4. Open dashboard
open http://localhost:3001   # Grafana, no login required
```

That's it. Your existing Anthropic key (or Claude Max OAuth token) flows through unchanged.

---

## Modes

### passthrough -- Claude Max plan / own key

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

Your Anthropic key stays where it is. gateii intercepts, tracks, and forwards.

### apikey -- shared team key

gateii holds one Anthropic key. Users get proxy keys from `admin.sh`.

```
# .env
PROXY_MODE=apikey
ANTHROPIC_API_KEY=sk-ant-...
```

```bash
# Issue a proxy key
./scripts/admin.sh add alice
# -> sk-proxy-4a7f...  (set as ANTHROPIC_API_KEY in client settings)
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

Keys are stored in `config/openresty/keys.json` (mounted read-only into the proxy).

---

## Monitoring

Grafana at `http://localhost:3001` -- no login, dashboard auto-provisioned.

### Metrics

| Metric | Labels | What it tells you |
|--------|--------|-------------------|
| `gateii_tokens_total` | user, provider, model, type | Input/output tokens consumed |
| `gateii_cost_dollars_total` | user, provider, model, type | Estimated cost (Anthropic pricing) |
| `gateii_requests_total` | user, provider, model | Request count |
| `gateii_request_duration_ms_total` | user, provider, model | Cumulative latency (/ requests = avg) |
| `gateii_upstream_errors_total` | user, provider, model | Non-200 upstream responses |
| `gateii_stop_reason_total` | user, provider, model, reason | end_turn / max_tokens / tool_use |
| `gateii_user_blocked` | user | 1 if user is currently blocked |

Prometheus scrape endpoint: `http://localhost:8888/metrics`

---

## Proxy routing

```bash
./scripts/admin.sh switch local    # route Claude Code through proxy (checks health first)
./scripts/admin.sh switch direct   # route directly to Anthropic (safe to stop proxy after)
```

**Important**: Always `switch direct` before stopping the proxy, or Claude Code loses its connection.

## Key management

```bash
./scripts/admin.sh status          # key count, blocked users
./scripts/admin.sh keys            # all keys, masked
./scripts/admin.sh add alice       # new random proxy key for alice
./scripts/admin.sh revoke sk-proxy-...
./scripts/admin.sh rotate alice    # new key, revoke all old ones
```

### Blocking and limits

```bash
./scripts/admin.sh block alice 86400    # block for 1 day
./scripts/admin.sh unblock alice
./scripts/admin.sh limit alice tokens_per_day 1000000
./scripts/admin.sh limits alice         # show today's usage
```

---

## Stack

| Container | Image | Port | Role |
|-----------|-------|------|------|
| `gateii-proxy` | `openresty/openresty:alpine` | 8888 | nginx + LuaJIT proxy + metrics |
| `gateii-prometheus` | `prom/prometheus` | 9090 | metrics storage |
| `gateii-grafana` | `grafana/grafana` | 3001 | dashboard |

All runtime state lives in nginx shared memory. Prometheus stores the time series.

### Vendored Lua libraries

These are included in `config/openresty/lua/resty/` because they're not in the `openresty:alpine` base image:

| Library | Purpose |
|---------|---------|
| `lua-resty-http` | HTTPS upstream requests + streaming |
| `lua-resty-string` | Hex encoding (used internally by lua-resty-http) |

---

## Configuration

All configuration via `.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `PROXY_MODE` | `passthrough` | `passthrough` or `apikey` |
| `PASSTHROUGH_USER` | _(key suffix)_ | Display name in passthrough mode |
| `ANTHROPIC_API_KEY` | -- | Required when `PROXY_MODE=apikey` |

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
| `ssl_verify=false` upstream | alpine has no CA bundle -- MITM on Anthropic connection possible. Fix: add `ca-certificates` to a custom Dockerfile |
| Auth cache TTL | Revoked keys work for up to 5 min -- reduce in `auth.lua` if needed |
| Request size limit | 10 MB max body (supports vision payloads) -- set in `nginx.conf` |
| Admin API | Internal only -- restricted to localhost and Docker network IPs |

---

## License

[GPL-3.0](LICENSE)
