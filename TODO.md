# gateii TODOs

Deferred improvements — actionable but not urgent.
Orchestrator: distribute to agents when prioritized.

---

## Active blockers

- **OpenRouter `:free` tier account-wide blocked (since 2026-07-31)**
  All tested `:free` models return HTTP 404 "No endpoints available matching
  your guardrail restrictions and data policy" via gateii's OpenRouter
  passthrough — including `cohere/north-mini-code:free`, which worked (HTTP
  200) on 2026-07-20. Tested 0/4 reachable: cohere/north-mini-code:free,
  google/gemma-4-31b-it:free, openai/gpt-oss-20b:free,
  nvidia/nemotron-3-super-120b-a12b:free.
  **Cause:** OpenRouter gates free-tier access behind a training-data opt-in
  at `openrouter.ai/settings/privacy`. Earlier assumption (only nemotron/
  poolside families needed it) is now wrong — the requirement appears
  extended account-wide, blocking the whole `:free` tier regardless of model.
  **Effect:** the entire free-model fallback path (`openrouter_free.lua`,
  `data/openrouter-free.json`, futurenotsub's candidate `worker-free` tier)
  is non-functional until the opt-in is enabled — verify with a live call,
  not the old per-model list. Budget gauges (`gateii_openrouter_free_*`)
  still report `exhausted=0`/`remaining=N` correctly since this is a
  routing-level 404, not a rate-limit — the metrics don't surface the
  failure mode, so don't trust them alone to confirm free-tier health.

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

- **nutc move — remaining follow-ups** (deploy itself DONE 2026-07-17,
  `scripts/deploy-nutc.sh`, prod at `http://100.64.0.2:8888`; local Colima
  stack is dev-only now):
  - garage Prometheus scrape job for nutc:8888/metrics + port the gateii
    Grafana dashboards to garage's Grafana (until then: no metric history,
    live gauges only).
  - nutc-side systemd timer for the futurenotsub sweep: claude CLI headless
    on Ubuntu. **Linux sandbox verified 2026-07-18, re-verified 2026-07-20:**
    srt (now **1.0.0**, parity with the Mac — the 0.0.66→1.0.0 bump kept the
    run.sh/sandbox.sh config schema, canary still green) + bubblewrap
    canary-green on nutc + garage (see futurenotsub PLAN.md for the Ubuntu
    24.04 dependency stack + the /tmp-tmpfs workdir fix in run.sh).
    **PATH caveat for the timer:** srt/node live in `claude-agent`'s
    `~/.local/bin`, added only by the login shell (`.profile`); a
    non-interactive `ssh host cmd` does not see them. The timer must run a
    login shell or set `PATH=$HOME/.local/bin:$PATH` explicitly.
    **Deploy status (2026-07-20):** claude-code 2.1.215 installed on nutc
    (pnpm-global; the native binary needs the manual `install.cjs` run since
    pnpm blocks build scripts), futurenotsub git-cloned as claude-agent
    (Forgejo token in `~/.git-credentials`), runner `scripts/nutc-sweep.sh`
    committed — it fetches `OPENROUTER_API_KEY` at run time from the gateii
    container via the docker group (claude-agent can't read bmadmin's gateii
    `.env`). Scheduling is a **crontab**, not systemd (claude-agent has no
    sudo), UTC-pinned to 00:15 — just after the free-budget reset. The Mac
    bridge is RETIRED (was producing only 503/api_error).
    **First real run (2026-07-20) validated the pipeline end-to-end** and
    surfaced two Linux-only srt faults the 2026-07-18 "sandbox verified" never
    caught — because that was only the canary (a workdir-write test), blind to
    both: (1) srt 1.0.0 forces `TMPDIR=/tmp/claude` but leaves `/tmp` read-only
    → claude EROFS, never starts (fixed in run.sh: pre-create + allowWrite
    exactly `/tmp/claude`); (2) srt runs claude in its own network namespace, so
    `127.0.0.1` is the sandbox's loopback, not the host's → gateii unreachable
    (fixed in nutc-sweep.sh: reach gateii via the tailnet IP `100.64.0.2`, which
    routes through srt's net proxy; gateii binds `0.0.0.0`). After both fixes
    claude reaches gateii and gets its 503 budget response. Run 0 is captured in the
    futurenotsub run chronicle (`results/runs/index.html`).
    **Push-back built + verified 2026-07-23** (`scripts/push-results.sh`, wired
    into nutc-sweep.sh; data-only commits, `.gitattributes merge=union`; nutc git
    identity `nutc-sweep`; push write-access dry-run-confirmed). The "test-run
    junk" cleanup was moot — the budget-blocked bringups never wrote a line.
    compose-ctl (crash-looping leftover of a manual full `compose up`) removed.
    **Only gate left: arm the cron (00:15 UTC) for the first real budget-window
    run.** The 50/day free budget stays the real bottleneck regardless of venue.
  - both need an interactive session with server access — not
    headless-worker tasks.

- **Route `agent-bench` through gateii**
  Currently the wrapper goes via gateii (passthrough) but `agent-bench` posts
  directly to oMLX. Two paths exercise different auth + bench results don't
  appear in gateii's per-user metrics. Single ingress would simplify.

- ~~Single source of truth for task definitions~~ ✅ Done — `config/agents/tasks.json`

## Competitive landscape (not urgent)

- **Benchmark proxy core against LiteLLM**
  gateii is the youngest of the three self-hosted-proxy candidates compared
  2026-07-31: LiteLLM (BerriAI/litellm, created 2023-07-27, 55k★, Python/Rust,
  cost tracking + virtual keys + budgets + 100+ providers) is ~2 years more
  mature than gateii (first commit 2026-04-04) and was mistakenly assumed to
  be a later/smaller entrant. router-for-me/CLIProxyAPI (created 2025-07-01,
  45k★, Go) solves a different problem (OAuth/subscription-account wrapping +
  protocol translation, not cost/budget governance) and isn't the right
  comparison target for this.
  Plan: check whether gateii's proxy core (cost tracking, rate limits,
  provider routing) can hold up against LiteLLM feature-for-feature. If
  LiteLLM's lead is real (it is — not hype, genuine 3-year maturity) and not
  worth re-competing with, consider porting gateii's bespoke pieces (omlx
  local-model routing via `scripts/agent`, git-tracking sidecar, claudii
  statusline integration, agents console) onto LiteLLM as an extension/plugin
  instead of maintaining the standalone Lua/nginx stack. Those pieces aren't
  LLM-gateway problems LiteLLM would ever solve itself — they're this
  project's own workflow layer, so switching the proxy core wouldn't remove
  that work, only change what it sits on top of.

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
