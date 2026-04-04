# gateii — Claude Code Instructions

## Project
Minimal self-hosted Anthropic API proxy. OpenResty (nginx + LuaJIT) + Redis + Python exporter.
No application framework, no Node.js, no external LLM calls from the project itself.

## Local development

```bash
# Start full stack
docker compose up -d --build

# Reload nginx after Lua changes (no restart needed)
docker exec gateii-proxy openresty -s reload

# Rebuild exporter after main.py changes
docker compose up -d --build --force-recreate exporter

# Tail proxy logs
docker logs -f gateii-proxy

# Redis CLI
docker exec -it gateii-redis redis-cli
```

## Key files

| File | Role |
|------|------|
| `config/openresty/lua/auth.lua` | Key validation, passthrough detection, rate limiting |
| `config/openresty/lua/handler.lua` | Cache L1/L2, proxy, SSE token parsing, header forwarding |
| `config/openresty/lua/tracking.lua` | Redis counters (tokens, latency, errors, cache, stop_reason) |
| `config/openresty/lua/providers/anthropic.lua` | Anthropic header building, token extraction |
| `config/exporter/main.py` | Prometheus metrics from Redis SCAN |
| `config/openresty/nginx.conf` | Env whitelist, shared dicts, route to auth/handler |

## Architecture decisions

- **ngx.ctx** passes auth state (user, upstream_key, auth_type) from auth.lua to handler.lua
- **passthrough mode** — client's key forwarded as-is; `ngx.ctx.upstream_auth_type` preserves Bearer vs x-api-key format (OAuth tokens must stay as Bearer)
- **SSE parsing** — chunks accumulated in memory during streaming, then parsed for `message_start` + `message_delta` events using `\r?\n` patterns
- **Cache key** — includes system prompt + all sampling parameters; streaming always bypasses cache
- **Cost metric** — calculated in the exporter (knows model names → prices), not in PromQL

## Providers

Each provider in `config/openresty/lua/providers/` must export:
- `_M.upstream_url` — base URL
- `_M.build_headers(upstream_key, auth_type)` — returns header table
- `_M.extract_tokens(body)` — returns `input_tokens, output_tokens, stop_reason`

## Testing

```bash
# Health check
curl http://localhost:8888/health

# Test proxy (passthrough — your real key)
curl http://localhost:8888/v1/messages \
  -H "Authorization: Bearer $ANTHROPIC_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":10,"messages":[{"role":"user","content":"hi"}]}'

# Check metrics
curl http://localhost:9091/metrics | grep gateii_
```

## Do not
- Read or commit `.env` (contains API keys)
- Use `docker system prune` (destroys Redis data volume)
- Change `ssl_verify` to true without adding CA certs to the image
