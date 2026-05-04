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

## Plumbing

- **`shortModel()` helper duplicated**
  Same suffix-stripping regex chain in `agents.js`, `statusline-omlx.sh`,
  and claudii's `claudii-sessionline`. If a new model family needs a new
  rule, all three must change. Either consolidate (probably not worth it)
  or accept it.
