# gateii — Claude Code Instructions

## Project
Minimal self-hosted Anthropic API proxy. 3 containers: OpenResty (nginx + LuaJIT), Prometheus, Grafana.
No Redis, no external dependencies, no application framework.

## Local development

```bash
# Start stack
bash scripts/docker-colima.sh compose up -d

# Reload nginx after Lua changes (no restart needed)
bash scripts/docker-colima.sh exec gateii-proxy openresty -s reload

# Tail proxy logs
bash scripts/docker-colima.sh logs -f gateii-proxy

# Smoke test
bash scripts/smoke-test.sh

# Switch Claude Code routing
./scripts/admin.sh switch local    # through local proxy (checks health first)
./scripts/admin.sh switch remote   # through a remote gateii instance (requires REMOTE_URL in .env)
./scripts/admin.sh switch direct   # direct to Anthropic
./scripts/admin.sh switch status   # show current ANTHROPIC_BASE_URL
```

## Safe dev workflow for proxy changes

When editing Lua or nginx config, switch to direct first so a broken proxy doesn't cut off Claude Code:

```bash
./scripts/admin.sh switch direct   # 1. go direct — Claude Code stays connected
# ... edit Lua/nginx, test changes ...
docker exec gateii-proxy openresty -s reload   # 2. reload to test
./scripts/admin.sh switch local    # 3. back to proxy when satisfied
```

## Emergency recovery (proxy broken, Claude Code cut off)

```bash
gateii-rescue          # alias: switch direct + restart proxy container
# then restart Claude Code to reconnect
```

Or from this repo directly:
```bash
./scripts/rescue.sh              # switch direct + restart proxy
./scripts/rescue.sh --no-restart # only switch direct (if Docker is also down)
```

## Gotchas

- **Docker commands:** always use `bash scripts/docker-colima.sh <args>` — auto-sets DOCKER_HOST for Colima, sandbox-safe after Claude Code restart. Never inline `DOCKER_HOST=unix://...` or `DOCKER_CONTEXT=colima docker ...` — those require dangerouslyDisableSandbox
- `ngx.print()` not `ngx.say()` for forwarded response bodies — `ngx.say` adds `\n`, breaks Content-Length
- Shared dict key separator is `|` not `:` — colons break key parsing (sanitize replaces `:|` with `_`)
- Rate limiter only active in `apikey` mode — passthrough has no rate limit
- `.env` is gitignored — never `git add .env`, use `.env.example` for defaults
- Proxy routing order: start stack → switch local; switch direct → stop stack (never reverse)
- Before editing Lua/nginx: `admin.sh switch direct` first — broken proxy cuts off Claude Code
- `data/keys.json` must use the structured schema (`{user, provider, upstream_key}`); flat `{key: "user"}` format is rejected by `schema.validate_keys` on startup — proxy then runs with empty auth cache (all requests 401)

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
| `data/keys.json` | Proxy-key → `{user, provider, upstream_key, ...}` mapping (apikey mode, gitignored, structured entries only) |
| `config/openresty/lua/bootstrap.lua` | HMAC challenge/exchange/confirm handshake for self-provisioning keys |
| `config/openresty/lua/admin_login.lua` | `/internal/admin/login` — session cookie issuance, failure counter |
| `config/openresty/lua/schema.lua` | Startup validation for `keys.json` and `limits.json` (rejects flat format) |
| `config/openresty/lua/circuit_breaker.lua` | Per-upstream breaker for repeated failures |

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

## Do not
- Read or commit `.env` (contains API keys)
- Change `ssl_verify` to true without adding CA certs to the image
- Stop the proxy before running `admin.sh switch direct` (loses Claude Code connection)
