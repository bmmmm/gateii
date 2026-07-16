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

- **`log.jsonl` rotation + cached aggregation**
  `/internal/admin/agents` re-reads + decodes the entire `log.jsonl` on
  every 2 s console poll. Today it's a few lines, but it grows monotonically.
  Cache the per-model aggregation in a shared dict keyed on the file's mtime,
  rotate at e.g. 10 MB. Same approach for `bench-results.json` re-decode
  on every Prometheus scrape (`metrics.lua`).

- **Single jq pass in `resolve_model_for_task`**
  `scripts/agent` runs three jq invocations per call to read routing.json.
  ~75 ms overhead. Combine into one jq `-r '...|join(" ")'` invocation.

- **Cache `omlx /v1/models/status`**
  `/internal/admin/agents` calls oMLX every 2 s per open Console tab. Cache
  the response in a shared dict for ~5 s. Pattern already exists for
  `_services_cache` in `compose-ctl`.

## Architecture

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

- **Generic upstream errors in admin responses**
  `/internal/admin/agents/bench` and `/models` echo lua-resty-http error
  strings (compose-ctl + `host.docker.internal:8000`) into the response
  body. Boundary-only relevance, but log and replace with "upstream
  unavailable".

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
