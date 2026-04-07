# gateii TODOs

Deferred improvements — actionable but not urgent.
Orchestrator: distribute to agents when prioritized.

---

## Metrics & Observability

- **Expose rate limit reset time as Prometheus gauge**
  `ratelimit_reset_ts` is stored in tracking.lua but not surfaced in metrics.lua.
  Add `gateii_rate_limit_seconds_until_reset` gauge (parse RFC3339 timestamp → seconds remaining).
  Enables a "Time until window reset" panel in Insights dashboard.
  Files: `config/openresty/lua/metrics.lua`, `config/openresty/lua/tracking.lua`

- **Rate limit window fill %**
  `gateii_rate_limit_tokens_remaining` exists but max window tokens is unknown to the proxy.
  Add `tokens_limit` per-provider to providers.json (e.g. Anthropic 5h = 200k, weekly = 5M).
  Expose as `gateii_rate_limit_tokens_max` gauge. Insights can then show "% of window consumed".
  Files: `config/openresty/lua/providers.json`, `config/openresty/lua/metrics.lua`

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

---

## Dashboard

- **Yearly trend panels: time range UX**
  Insights "Yearly Cost Trend" / "Yearly Token Trend" require manually switching to a 1y range.
  Consider a dashboard variable or a "Last 12 months" quick-select button.
  File: `grafana/dashboards/insights.json`
