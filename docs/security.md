# Security

gateii exposes an HTTP proxy and an admin API. This page summarises the
security posture and the controls in place. Full admin-API reference:
[admin-api.md](admin-api.md).

## Summary

| Topic | Status |
|-------|--------|
| SSL verification to upstreams | Enabled — `ca-certificates` installed at container startup |
| Auth cache TTL | Revoked keys work for up to 5 min — reduce in `auth.lua` if needed |
| Request size limit | 10 MB max body (supports vision payloads) — set in `nginx.conf` |
| Admin API auth | Internal-only: IP allow-list + `ADMIN_TOKEN` (cookie or header), constant-time compare |
| Admin login brute-force | `limit_req_zone adminauth 5r/m` with burst 3 on `/internal/admin/login` (429 on exhaustion) |
| Admin fail-closed | `apikey` mode without `ADMIN_TOKEN` returns 503 on `/internal/admin/*` (passthrough stays open) |
| Admin session | HttpOnly, Secure, SameSite=Strict cookie; crypto-random id; 1 h TTL |
| Console CSP | `script-src 'self' 'nonce-<N>'` — no inline scripts without per-request nonce |
| Bootstrap handshake | HMAC-SHA256, constant-time proof compare, one-time code, auto-revoke on failed install |
| Port bindings | `PROXY_BIND`, `GRAFANA_BIND`, `PROMETHEUS_BIND` default to `127.0.0.1` — set to `0.0.0.0` only for explicit LAN exposure |

## Admin API authentication

The admin surface at `/internal/admin/*` accepts two mechanisms:

- **Session cookie** — `POST /internal/admin/login` with `{token}` sets
  `admin_session=<hex>; HttpOnly; Secure; SameSite=Strict` (1 h TTL).
  Used by the `/console` web UI.
- **Header** — `X-Admin-Token: <ADMIN_TOKEN>`. Used by
  `scripts/admin.sh` and curl.

Set `ADMIN_TOKEN` (≥ 32 random hex bytes) in `.env` for production.

### Fail-closed matrix

| `PROXY_MODE` | `ADMIN_TOKEN` set? | `/internal/admin/*` behaviour |
|--------------|:---:|---|
| `apikey` | yes | Normal — cookie or header required |
| `apikey` | **no** | **503 on every request** (fail-closed — there are server-side keys to protect) |
| `passthrough` | yes | Normal |
| `passthrough` | no | Open behind IP allow-list (no server-side secrets to protect) |

Token compares are constant-time. `/internal/admin/login` is rate-limited
at 5 req/min per IP.

## Network exposure

Default: everything binds to `127.0.0.1`. To expose beyond loopback:

```ini
# .env
PROXY_BIND=0.0.0.0
```

**Only do this if:**

- You're running `PROXY_MODE=apikey` with real keys in `data/keys.json`
  (so unauthenticated requests get 401), AND
- You've set a strong `ADMIN_TOKEN`, AND
- You understand the LAN / internet boundary of your deployment.

Or put gateii behind a reverse proxy with its own auth and TLS (Caddy,
nginx, Cloudflare Tunnel, …).

## Secrets hygiene

- `.env` is `.gitignore`d. **Never `git add .env`.** Use `.env.example`
  for defaults.
- Proxy keys (`sk-proxy-...`) are stored in `data/keys.json` — also
  gitignored. Share via the bootstrap handshake, not over chat:
  [bootstrap.md](bootstrap.md).
- Admin token rotation: `ADMIN_TOKEN` has no session revocation mechanism
  currently. To rotate: change in `.env`, `gateii reload`, issue new
  sessions from `/console` or CLI.
- Log output: nginx access logs contain the proxy key in headers only if
  you explicitly log those headers. Default config does not. Still, scan
  any logs before sharing.

## Bootstrap handshake

Copy-pasting `sk-proxy-...` keys over SSH / Slack / email is a common
leak vector. The bootstrap handshake replaces it with a one-time HMAC-SHA256
flow:

1. Admin issues a one-time code + HMAC secret.
2. Client (`scripts/gateii-connect.sh`) performs challenge → exchange →
   confirm.
3. If any step fails or the client never confirms, the key auto-revokes.

Full protocol: [bootstrap.md](bootstrap.md).

## Upstream SSL

gateii's OpenResty image installs `ca-certificates` at build time and
nginx's `proxy_ssl_verify` is `on`. Don't flip to `off` — it disables
certificate validation for every upstream request. If you need to reach
a private API with a custom CA, add the CA to the image and rebuild.

## Console CSP

The admin console (`/console`) serves HTML with
`Content-Security-Policy: script-src 'self' 'nonce-<N>'`. Every
`<script>` tag needs a per-request nonce. No `unsafe-inline`, no
`unsafe-eval`. This mitigates XSS even if a future bug reflects user
input.

## Known risks

- **Counter exposure:** `/metrics` is unauthenticated and exposes user
  names as labels. If you LAN-expose the proxy, also bind-restrict the
  metrics endpoint or put it behind auth.
- **Admin token in URL:** some misuse of the admin API with
  `?token=<val>` query parameters is possible. Prefer headers; never log
  request URIs with tokens.
- **Shared-dict TTL drift:** blocked users auto-unblock at midnight UTC —
  not the user's local midnight. Document this when setting team policy.
