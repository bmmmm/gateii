# gateii — Claude Code Instructions

## Project
Minimal self-hosted Anthropic API proxy. 3 containers: OpenResty (nginx + LuaJIT), Prometheus, Grafana.
No Redis, no external dependencies, no application framework.

## Local development

```bash
# Start stack
DOCKER_CONTEXT=colima docker compose up -d

# Reload nginx after Lua changes (no restart needed)
docker exec gateii-proxy openresty -s reload

# Tail proxy logs
docker logs -f gateii-proxy

# Smoke test
bash scripts/smoke-test.sh

# Switch Claude Code routing
./scripts/admin.sh switch local    # through proxy (checks health first)
./scripts/admin.sh switch direct   # direct to Anthropic
```

## Gotchas

- `DOCKER_CONTEXT=colima` required — no Docker Desktop, Colima provides the daemon
- `ngx.print()` not `ngx.say()` for forwarded response bodies — `ngx.say` adds `\n`, breaks Content-Length
- Shared dict key separator is `|` not `:` — colons break key parsing (sanitize replaces `:|` with `_`)
- Rate limiter only active in `apikey` mode — passthrough has no rate limit
- `.env` is gitignored — never `git add .env`, use `.env.example` for defaults
- Proxy routing order: start stack → switch local; switch direct → stop stack (never reverse)

## Key files

| File | Role |
|------|------|
| `config/openresty/lua/auth.lua` | Key validation, passthrough detection, blocking, rate limiting |
| `config/openresty/lua/handler.lua` | Proxy to upstream, SSE token parsing, header forwarding |
| `config/openresty/lua/tracking.lua` | Shared dict counters (tokens, latency, errors, stop_reason) |
| `config/openresty/lua/metrics.lua` | Prometheus exposition format from shared dicts |
| `config/openresty/lua/admin_api.lua` | HTTP admin API (block/unblock/limit, /providers, /llm-prices, /openrouter-models) |
| `config/openresty/lua/providers/anthropic.lua` | Anthropic header building, token extraction |
| `config/openresty/lua/providers.json` | Multi-provider pricing config, active provider selector |
| `config/openresty/nginx.conf` | Env whitelist, shared dicts, routes, /internal/prometheus proxy |
| `data/keys.json` | API key → user mapping (apikey mode, gitignored) |

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

## Providers

Each provider in `config/openresty/lua/providers/` must export:
- `_M.upstream_url` — base URL
- `_M.build_headers(upstream_key, auth_type)` — returns header table
- `_M.extract_tokens(body)` — returns `input_tokens, output_tokens, stop_reason`

## Testing

```bash
curl http://localhost:8888/health
curl http://localhost:8888/metrics | grep gateii_
bash scripts/smoke-test.sh
```

## Do not
- Read or commit `.env` (contains API keys)
- Change `ssl_verify` to true without adding CA certs to the image
- Stop the proxy before running `admin.sh switch direct` (loses Claude Code connection)
