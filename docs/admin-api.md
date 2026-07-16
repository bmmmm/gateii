# Admin API

HTTP admin surface at `/internal/admin/*`. Used by `scripts/admin.sh`, the
`/console` web UI, and ad-hoc curl.

## Auth

Two mechanisms, both accepted on every endpoint:

1. **Session cookie** — `admin_session=<hex>` (HttpOnly, SameSite=Strict,
   Path=`/internal/admin`, 1 h TTL; `Secure` added when served over HTTPS).
   Issued by `POST /internal/admin/login`
   with body `{token: "<ADMIN_TOKEN>"}`. Used by the console with
   `fetch(..., { credentials: "include" })`.
2. **Header** — `X-Admin-Token: <ADMIN_TOKEN>`. Used by `admin.sh` and curl.

Additionally, the nginx config allow-lists the admin routes to `127.0.0.1` +
Docker bridge networks (`172.16.0.0/12`). Remote access therefore requires
both network reachability and a valid token.

Token comparisons use a constant-time equality (`bootstrap._consttime_eq`)
to avoid timing side-channels on login and `X-Admin-Token` checks. The
login endpoint is additionally rate-limited at **5 req/min per IP**
(burst 3, returns 429) to make brute-force infeasible even on the local
loopback.

Without `ADMIN_TOKEN` the behaviour depends on `PROXY_MODE`:

- **`PROXY_MODE=apikey`** — fail-closed. `/internal/admin/login` and the
  admin API both return `503 {"error":"Admin API disabled — set ADMIN_TOKEN in .env"}`.
  This is the default so that keys.json / limits.json cannot be mutated by
  anything reaching the admin network without operator intent.
- **`PROXY_MODE=passthrough`** — read-only without a token. Login returns
  `{"ok":true,"auth":"none"}` and `GET` requests from allow-listed IPs are
  served without a token (so the console dashboard works zero-config). Every
  mutating method (`POST`/`PUT`/`DELETE`) is refused with
  `403 {"error":"Admin mutations require ADMIN_TOKEN — set it in .env"}` —
  there is no server-side secret to protect state mutation with, so it's
  disabled rather than left open (also closes browser CSRF for mutations
  and unauthenticated sibling-container lateral movement).

Production: always set `ADMIN_TOKEN` (≥ 32 random hex bytes) regardless
of mode.

---

## Session endpoints

| Method | Path | Body | Response |
|---|---|---|---|
| `POST` | `/internal/admin/login` | `{token}` | `Set-Cookie: admin_session=...; HttpOnly; ...` + `{ok: true}` |
| `POST` | `/internal/admin/logout` | — | clears cookie + drops session; `{ok: true}` |

Login failures bump `counters:admin_login_failures` (7-day retention) — useful
for alerting on brute-force attempts.

---

## Read-only endpoints

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/internal/admin/status` | Key count, blocked users, uptime |
| `GET` | `/internal/admin/usage?user=alice` | Today's usage for one user |
| `GET` | `/internal/admin/usage-all` | Aggregated usage across all users |
| `GET` | `/internal/admin/overview` | Combined summary for the console homepage |
| `GET` | `/internal/admin/keys` | All keys (masked `upstream_key`) |
| `GET` | `/internal/admin/providers` | `providers.json` contents |
| `GET` | `/internal/admin/llm-prices` | Cached llm-prices.com snapshot |
| `GET` | `/internal/admin/openrouter-models` | Top weekly programming models with pricing (12 h cache). `?free=1`: all currently-listed `:free` models with `context_length` (1 h cache) |
| `GET` | `/internal/admin/openrouter-free` | OpenRouter free-tier config `{pool, default, routes, long_context_threshold, daily_limit, minute_limit}` plus a computed `budget` object (`{minute:{used,limit,remaining}, day:{...}, exhausted_until?, exhausted_limit?}` — proxy-side request counts + the exhaustion signal captured from upstream 429s). `budget` is never persisted (PUT drops unknown keys) |
| `GET` | `/internal/admin/health` | Component reachability: proxy, Prometheus, Grafana + upstream error rate |
| `GET` | `/internal/admin/bootstrap` | Pending codes + active confirm sessions |
| `GET` | `/internal/admin/agents` | Local-omlx-agent state: active, recent runs, routing, bench matrix, omlx_status |
| `GET` | `/internal/admin/diagnostics?include=agents` | Agents-page diagnostics: omlx connectivity, file sizes, bench freshness, smart-skip log |
| `GET` | `/internal/admin/services` | All compose services + their state (proxied through the `compose-ctl` sidecar). Includes services never started (`state: "not_created"`) |
| `GET` | `/internal/admin/git-tracking` | Current per-repo git-tracking config; `{"default_author":"","interval":300,"repos":[]}` if no config file yet |
| `GET` | `/internal/admin/agents/idle-config` | Per-model idle-unload TTL config (proxied through `compose-ctl`): `{models:{"<id>":{ttl_seconds,enabled}},default_ttl_seconds}` |

---

## Mutating endpoints

### Keys

| Method | Path | Body | Effect |
|---|---|---|---|
| `POST` | `/internal/admin/addkey?user=<u>` | `{key, provider, upstream_key}` | Add a proxy key. All three fields required (`key` and `upstream_key` length/format-checked, `provider` must match `^[a-z][a-z0-9_]+$`). `409` if the key already exists — pass `?force=1` to overwrite (response includes `overwrote: true`). Clears the `auth_cache` entry for the key. |
| `POST` | `/internal/admin/revoke-key` | `{key}` | Evict the key's `auth_cache` entry (both cache directions) across all workers so revocation is immediate instead of waiting out the TTL. `400` if `key` is missing. Doesn't touch `keys.json` — remove the entry there separately. |

Writes go through atomic temp + rename. See [keys.md](keys.md) for the
full `keys.json` schema.

### Blocking + limits

| Method | Path | Body | Effect |
|---|---|---|---|
| `POST` | `/internal/admin/block` | `{user, ttl?}` | Block user for `ttl` seconds (default = until midnight UTC) |
| `POST` | `/internal/admin/unblock` | `{user}` | Remove block |
| `POST` | `/internal/admin/limit` | `{user, key, value}` | Set a limit key (e.g. `tokens_per_day`) |

Limits persist to `data/limits.json` via the proxy (loaded at startup by
`init_worker_by_lua_block`, validated by `schema.validate_limits`).

### Bootstrap

| Method | Path | Body | Effect |
|---|---|---|---|
| `POST` | `/internal/admin/bootstrap` | `{user, provider, upstream_key, ttl?}` | Create one-time code + secret |
| `DELETE` | `/internal/admin/bootstrap/<code>` | — | Revoke pending (before exchange) |

The create response is the only place the HMAC secret is disclosed — it is
not stored in a reversible form. See [bootstrap.md](bootstrap.md).

### Services

| Method | Path | Body | Effect |
|---|---|---|---|
| `POST` | `/internal/admin/services/<name>/<action>` | — | `<action>` is one of `start\|stop\|restart\|recreate`, forwarded to the `compose-ctl` sidecar. `400` for an unknown action or a service not in `docker compose config --services`. Restarting/recreating the proxy itself (`openresty`) is scheduled async and returns `202` immediately (the request would otherwise die mid-flight when the container restarts). `504` if the underlying `docker compose` call times out (30 s). |

Requires `INTERNAL_TOKEN` to be set — without it, `compose-ctl` runs in a
degraded mode that serves only `/health` and 503s every other path,
including this one.

### Git tracking

| Method | Path | Body | Effect |
|---|---|---|---|
| `PUT` | `/internal/admin/git-tracking` | Full config: `{default_author?, interval?, platform_authors?, repos:[{path, author?, platform?, alias?}]}` | Replaces `data/git-tracking.json`. `repos[].path` must be absolute and must not contain `..`; `platform` (if set) must match `[a-z0-9_-]+`. `400` on invalid JSON, a path-traversal attempt, or a schema violation; `500` on write failure. Returns `{ok: true, repos: <count>}`. |

Consumed by `scripts/git-tracking.sh` in the git-tracking sidecar and by
the `/console/git` tab.

### OpenRouter free tier

| Method | Path | Body | Effect |
|---|---|---|---|
| `PUT` | `/internal/admin/openrouter-free` | `{pool:[":free" ids], default:":free" id \| "", routes:{<category>:[":free" ids]}, long_context_threshold:int, daily_limit:int, minute_limit:int}` | Replaces `data/openrouter-free.json`. Every `:free` array is capped at 3 (OpenRouter's models-array limit), ids must end in `:free`, no dups; category keys are `[a-z][a-z0-9_]*`; `long_context_threshold`/`daily_limit`/`minute_limit` positive ints (limits are display-only budget caps: 20/min + 50/day unfunded, 1000/day with ≥10 lifetime credits). Unknown keys (e.g. the computed `budget` from GET) are dropped. `400` on a schema violation; `500` on write failure. Returns `{ok, pool:<count>, default}`. |

Read by `handler.lua` (via `openrouter_free.lua`) on every `:free` request and
managed from the `/console/free` tab. The capability router classifies each
request (`x-gateii-task` header > vision > long-context > general) and routes it
to that category's ordered model list; the first entry becomes the model, the
whole list the fallback `models` array. `default`/`pool` are the fallback when a
category has no route.

### Local agents (omlx)

| Method | Path | Body | Effect |
|--------|------|------|--------|
| `POST` | `/internal/admin/models` | `{action:"load"\|"unload",model:"<id>"}` | Proxy to oMLX `/v1/models/<id>/(load\|unload)`. Model id validated against `^[A-Za-z0-9._-]+$` |
| `POST` | `/internal/admin/agents/bench` | `{force?:bool}` | Spawn `scripts/agent-bench` via the `compose-ctl` sidecar. 202 on start, 409 if a bench is already in flight. `force=true` bypasses smart-skip |
| `PUT`/`POST` | `/internal/admin/agents/idle-config` | `{models?:{"<id>":{ttl_seconds:0-86400, enabled?:bool}}, default_ttl_seconds?:0-86400}` | Replaces the per-model idle-unload TTL config used by `compose-ctl`'s idle watcher (unloads a loaded model after `ttl_seconds` without use). Always forwarded downstream as `POST` — `compose-ctl` only implements GET/POST. `400` on an out-of-range or wrong-typed value. |

See [agents.md](agents.md) for the full feature description.

---

## Error shape

All errors use the same JSON envelope:

```json
{ "error": "message explaining what went wrong" }
```

HTTP codes in use: `400` (bad request body / params), `401` (auth), `403` (IP
allow-list rejection from nginx, or a mutating call in `passthrough` mode
with no `ADMIN_TOKEN` set), `404` (unknown endpoint / unknown resource),
`405` (wrong method), `409` (conflicting key / bench already running),
`500` (persist failure), `503` (`ADMIN_TOKEN` unset on login/apikey mode),
`504` (a proxied `compose-ctl` action timed out).

---

## Console integration notes

`/console` is served from `config/openresty/html/console.html`. All inline
`<script>` tags carry a per-request CSP nonce injected by `console_serve.lua`.
The response header sets:

```
Content-Security-Policy:
    default-src 'self';
    script-src 'self' 'nonce-<N>';
    style-src 'self' 'unsafe-inline';
    img-src 'self' data:;
    connect-src 'self';
```

Fetch calls use `credentials: "include"` so the `admin_session` cookie is sent
automatically. No `X-Admin-Token` header is attached from the browser.

---

## Related

- `config/openresty/lua/admin_api.lua` — endpoint dispatch
- `config/openresty/lua/admin_login.lua` — session cookie issuance
- `config/openresty/nginx.conf` — routes, IP allow-list, CSP
- `scripts/admin.sh` — CLI wrapping the same API
