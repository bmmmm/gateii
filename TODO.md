# gateii TODOs

Deferred improvements — actionable but not urgent.
Orchestrator: distribute to agents when prioritized.

---

## Performance / Scaling

- **Prefix-based iteration in hot paths**
  `metrics.lua` and `admin_api.lua` cap dict scans at `MAX_ITER_KEYS=5000` — safe
  up to ~500 users/models. Beyond that, replace `get_keys()` with prefix iteration
  or split counters into separate dicts per purpose (daily, stops, effort, …).
  Only worthwhile once counter count actually pressures the cap.
  Files: `config/openresty/lua/metrics.lua`, `config/openresty/lua/admin_api.lua`

- **`log.jsonl` rotation + `bench-results.json` decode cache**
  The per-model aggregation cache is ✅ done (`agents_log_cache`, size-keyed,
  in `admin_api.lua`). Still open: rotate `log.jsonl` at e.g. 10 MB (it grows
  monotonically), and cache `bench_agg.load()`'s decode of `bench-results.json`
  (re-parsed on every Prometheus scrape — harmless at current file size).

- ~~Single jq pass in `resolve_model_for_task`~~ ✅ Done — `scripts/agent`
  reads routing.json with one jq program.

- ~~Cache `omlx /v1/models/status`~~ ✅ Done — 5 s TTL in `or_cache`
  (`omlx_status_cache` in `admin_api.lua`).

## Architecture

- **Move the :free ingress (and the daily worker-free sweep) to nutc**
  Decided direction 2026-07-17: budget-metered always-on jobs belong on the
  24/7 server, not a sleeping laptop — and ONE gateii instance counting the
  account-wide OpenRouter budget beats two drifting estimates. Groundwork
  exists: `~/servers/nutc/server.conf` already has `LOCAL_GATEII_DIR`, the
  `claude-agent` deploy identity + sandbox-usable SSH are in place
  (scalendarii pattern), and nutc's convention is openresty-only stacks
  (Prometheus/Grafana live on garage → add a scrape job there instead of
  shipping gateii's own). Work items: openresty-only compose variant +
  secrets (`OPENROUTER_API_KEY`) on nutc; garage Prometheus scrape job +
  dashboard row; claude CLI headless on Ubuntu incl. **verifying the Linux
  sandbox (bubblewrap)** — the eval-escape lesson makes an unsandboxed
  harness a hard no; futurenotsub clone + systemd timer running
  `sweep-free.sh` with results committed+pushed by a bot identity. Until
  then a durable Mac cron (09:37, 7-day auto-expiry) bridges the mini-matrix.
  Needs an interactive session with server access — not a headless-worker task.

- **Route `agent-bench` through gateii**
  Currently the wrapper goes via gateii (passthrough) but `agent-bench` posts
  directly to oMLX. Two paths exercise different auth + bench results don't
  appear in gateii's per-user metrics. Single ingress would simplify.

- ~~Single source of truth for task definitions~~ ✅ Done — `config/agents/tasks.json`

## Defense in depth

- **Auth on `compose-ctl /run-bench`**
  compose-ctl listens on `0.0.0.0:8090` inside the Docker network. Any
  sibling container could POST `/run-bench` or `/services/<name>/<action>`
  without auth. Today the proxy is the only intended client. Mitigation:
  shared-secret header injected by openresty.

- ~~Generic upstream errors in admin responses~~ ✅ Done — `/agents/bench`
  and `/models` log the detail and answer `{"error":"upstream unavailable"}`.
  `/diagnostics` still echoes error detail by design (admin-only debug surface).

## Deferred from the 2026-07 review

- **Console "Revoke key" button**
  The console lists keys (masked) and can add them, but has no revoke UI. Not a
  one-line fix: `/internal/admin/revoke-key` only evicts the auth cache — it does
  NOT remove the entry from `keys.json`, so the key re-validates on the next
  request — and the key list is masked, so the browser never has the full key.
  Needs a revoke-by-user endpoint that deletes from keys.json AND evicts the cache
  (what `admin.sh revoke` does in two steps), then a per-row button.
  Files: `admin_api.lua`, `html/console/static/overview.js`.

- ~~OpenRouter free-tier budget visibility (NOT proxy-side escalation)~~ ✅ Done —
  proxy-side request counting (minute + UTC-day windows, an estimate: success
  responses carry no rate-limit headers) + authoritative exhaustion signal from
  platform-limit 429 `X-RateLimit-Reset` → 503 + reset time on `:free` requests
  while exhausted. Gauges `gateii_openrouter_free_*`; console Free tab shows the
  budget + configurable limits. No proxy-side escalation (routing boundary).
  Note: `/api/v1/auth/key` was evaluated and rejected — it reports credit usage,
  not free-request counts, so it can't see the 50/day window.

- **Low-severity shell edge cases** (no current failure, left as-is)
  - `git-tracking.sh`: two tracked repos with the same basename collide on the
    staged symlink (second silently wins). Disambiguate + warn.
  - `proxy-hint.sh`: PID-keyed hint-count file in /tmp is never pruned; PID reuse
    can carry a stale ≥MAX counter into an unrelated session.
  - `compose-ctl.py`: `list_services` comma-splits the flat Docker Labels string;
    a label VALUE containing a comma (compose injects one for `config_files` with
    an override) mis-parses. Harmless today (that key is never read); switch to
    `docker inspect --format '{{json .Config.Labels}}'` if it ever matters.

## Plumbing

- **`shortModel()` helper duplicated**
  Same suffix-stripping regex chain in `agents.js`, `statusline-omlx.sh`,
  and claudii's `claudii-sessionline`. If a new model family needs a new
  rule, all three must change. Either consolidate (probably not worth it)
  or accept it.
