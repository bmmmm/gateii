# gateii TODOs

Deferred improvements — actionable but not urgent.
Orchestrator: distribute to agents when prioritized.

---

## Performance / Scaling

- **`get_keys(0)` in hot paths**
  `metrics.lua`, `admin_api.lua` (/health, /status, /usage-all) all call `get_keys(0)` —
  fetches all keys into memory per request. Fine up to ~500 users/models.
  If user count grows, consider prefix-based iteration or splitting into separate dicts.
  Files: `config/openresty/lua/metrics.lua`, `config/openresty/lua/admin_api.lua`

- **`auth_cache` shared dict size**
  Currently 1m (nginx.conf line 44) — holds ~10k entries, sufficient for a personal proxy.
  Bump to 5m if key count grows significantly.
  File: `config/openresty/nginx.conf`

---

## Security / Hardening

- **Rate limiting on `/internal/admin/*`**
  Currently protected by IP ACL (127.0.0.1 + Docker subnets) only — no per-endpoint rate limit.
  If ever exposed beyond localhost, add `limit_req_zone` in nginx.conf.
  File: `config/openresty/nginx.conf`
