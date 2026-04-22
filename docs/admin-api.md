# Admin API

HTTP admin surface at `/internal/admin/*`. Used by `scripts/admin.sh`, the
`/console` web UI, and ad-hoc curl.

## Auth

Two mechanisms, both accepted on every endpoint:

1. **Session cookie** — `admin_session=<hex>` (HttpOnly, Secure, SameSite=Strict,
   Path=`/internal/admin`, 1 h TTL). Issued by `POST /internal/admin/login`
   with body `{token: "<ADMIN_TOKEN>"}`. Used by the console with
   `fetch(..., { credentials: "include" })`.
2. **Header** — `X-Admin-Token: <ADMIN_TOKEN>`. Used by `admin.sh` and curl.

Additionally, the nginx config allow-lists the admin routes to `127.0.0.1` +
Docker bridge networks (`172.16.0.0/12`). Remote access therefore requires
both network reachability and a valid token.

Without `ADMIN_TOKEN` in the environment the proxy still starts, but login
returns 503 and the console is effectively read-only — the IP allow-list is
the only wall. Production: always set `ADMIN_TOKEN` (≥ 32 random hex bytes).

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
| `GET` | `/internal/admin/openrouter-models` | Top-10 weekly programming models (12 h cache) |
| `GET` | `/internal/admin/health` | Component reachability: proxy, Prometheus, Grafana + upstream error rate |
| `GET` | `/internal/admin/bootstrap` | Pending codes + active confirm sessions |

---

## Mutating endpoints

### Keys

```http
POST /internal/admin/addkey?user=<u>
Content-Type: application/json

{ "key": "sk-proxy-...", "provider": "<p>", "upstream_key": "<k>" }
```

All three JSON fields required. Writes the structured entry via atomic
temp + rename, clears the auth cache for that key. See
[keys.md](keys.md) for the schema.

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

---

## Error shape

All errors use the same JSON envelope:

```json
{ "error": "message explaining what went wrong" }
```

HTTP codes in use: `400` (bad request body / params), `401` (auth), `403` (IP
allow-list rejection, returned by nginx), `404` (unknown endpoint / unknown
resource), `405` (wrong method), `500` (persist failure), `503` (`ADMIN_TOKEN`
unset on login).

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
