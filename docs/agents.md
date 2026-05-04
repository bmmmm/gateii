# Local agents (omlx)

Optional layer that routes simple tasks (commit messages, summaries, doc
comments, structured extractions, …) to a local Apple-Silicon LLM via
[oMLX](https://github.com/jundot/omlx) instead of burning Claude API tokens
on them. Empirically picked per task: `Qwen3.5-9B`, `gemma-4-e2b`, or
`gemma-4-26b` — all running on the host.

```
Claude Code (Bash invocation)            Re-run from the Console
        │                                    │
        ▼                                    ▼
  scripts/agent run <task>          POST /internal/admin/agents/bench
        │                                    │
        ▼                                    ▼ (compose-ctl spawns)
  POST :8888/v1/messages             scripts/agent-bench
  x-provider: omlx                          │
        │                                   ▼
        ▼                            POST :8000/v1/messages
  oMLX :8000                                │
  Qwen3.5-9B / gemma-4-*                    ▼
        │                            (results land in
        ▼                              data/agents/)
  data/agents/active.json
  data/agents/log.jsonl
```

State and routing are file-driven; visualization is the Console **Agents**
tab at `http://localhost:8888/console/agents`. Permanent history goes to
Prometheus via `gateii_omlx_*` gauges.

## Install oMLX (host-side, one-time)

```bash
brew tap jundot/omlx https://github.com/jundot/omlx
brew install omlx
omlx serve --model-dir ~/.omlx/models    # or via the desktop app
# Admin web-UI: http://localhost:8000/admin   (download / load / unload models)
# OpenAPI:      http://localhost:8000/openapi.json
```

oMLX exposes both the OpenAI (`/v1/chat/completions`) and Anthropic
(`/v1/messages`) APIs. gateii routes through the Anthropic path; the
provider patch in `config/openresty/lua/providers/omlx.lua` reuses
`anthropic.extract_tokens`.

**oMLX usage quirk:** `/v1/messages` responses report `input_tokens=0` with
the actual prompt size in `cache_creation_input_tokens`. The provider
sums all three input fields so gateii's tracking + Prometheus counters
stay accurate.

## Use the wrapper

```bash
echo "<input>" | scripts/agent run <task>
scripts/agent tasks                   # list available tasks
scripts/agent list                    # currently running + last 10 records
scripts/agent count-tokens            # POST /v1/messages/count_tokens (no LLM call)
```

| Task | Use it for |
|------|------------|
| `commit-msg` | Generate a single-line conventional commit message from a diff |
| `summarize-file` | "What does this file do?" — one sentence (≤2k token input) |
| `classify-yesno` | Yes/no decision with a 10-word justification |
| `rename` | "Better name for `x`?" — three suggestions |
| `doc-comment` | One-line docstring for a function |
| `extract-json` | Pull structured fields out of unstructured text |
| `explain-line` | One-line explanation of a code line |
| `refactor-suggestion` | One specific refactor: what + why |
| `ambiguity-check` | Test whether a request is unambiguous; replies `AMBIGUOUS:` if not |
| `unix-recipe` | Three shell-command suggestions for a task |
| `code-gen-short` | Short function (≤250 tokens output) from a spec |
| `tldr` | Paragraph → one or two-sentence summary |
| `slug` | Title → URL-safe slug |
| `regex` | NL description → single PCRE pattern |
| `error-explain` | Stack trace / error message → one-sentence cause |
| `keywords` | Text → JSON array of top 5 keywords |

Lock is mkdir-based (`data/agents/lock.d`), max one concurrent agent.

## Bench-driven model picker

```bash
scripts/agent-bench               # default: smart re-run, skips models with cached results
scripts/agent-bench --force       # re-bench every cell from scratch (slow)
scripts/agent-bench --quick       # 1 trial, default model only
scripts/agent-bench --task TASK   # bench only this task across all models
```

Outputs to `data/agents/`:
- `bench-results.json` — per-trial raw data with `model_created` map for smart-skip
- `bench-report.md` — human-readable matrix
- `routing.json` — picked `(model, max_tokens)` per task

The wrapper consults `routing.json` and switches *away* from the default
model only on a *qualitative* win (default fails, candidate passes 100 %).
Marginal latency advantages are ignored so we don't burn 15-21 GB of RAM
for an 80 ms saving.

The smart-skip rule: skip a model's cells iff (a) results for it exist
in the previous bench AND (b) its omlx-registration `created` timestamp
is unchanged. Use `--force` after upgrading oMLX or replacing model
weights.

## Visualization (Console Agents tab)

`http://localhost:8888/console/agents` shows, polled every 2 s:

- **Currently running** — live `active.json`, prefixed `bench:` while a
  benchmark is in flight
- **Recent runs** — last 50 from `log.jsonl`, mixed wrapper + bench-summary
  rows
- **Models** — `omlx /v1/models/status` (loaded / idle, RAM, last-access)
  with per-model **load / unload** buttons + an **Unload all** button
- **Bench matrix** — task × model heatmap (green = 100 % pass, yellow =
  partial, red = failed; cell shows pass-% + median latency, winner-dot
  per row). **Re-run bench** + **Force re-run** buttons trigger
  `scripts/agent-bench` in the compose-ctl sidecar
- **Routing** — current per-task choice from `routing.json`
- Footer **diagnostics** link → `?include=agents` → omlx connectivity,
  file sizes, bench freshness, smart-skip log

## Permanent history (Prometheus)

`metrics.lua` re-emits the latest bench-results + routing data on every
scrape so Grafana keeps the time series long after the JSON file is
overwritten:

| Metric | Labels | What |
|--------|--------|------|
| `gateii_omlx_bench_pass_rate` | `task`, `model` | 0..1 fraction of compliant trials |
| `gateii_omlx_bench_latency_seconds` | `task`, `model`, `quantile="0.5"` | Median latency in the last bench |
| `gateii_omlx_bench_trials_total` | `task`, `model` | Trial count per cell |
| `gateii_omlx_bench_generated_timestamp_seconds` | — | When the latest bench finished (Unix epoch) |
| `gateii_omlx_model_created_timestamp_seconds` | `model` | When the model was registered with oMLX |
| `gateii_omlx_routing_choice` | `task`, `model` | 1.0 = currently picked for that task |

Plus the standard per-request counters (`gateii_requests_total`,
`gateii_tokens_total`, `gateii_request_duration_ms_total`) work as-is —
the agent wrapper goes through gateii so its calls are labeled
`provider="omlx",model="<id>"` like everything else.

## Statusline integration (claudii)

The data file `data/agents/active.json` is the source of truth for "what's
running right now". Display logic lives in
[claudii](https://github.com/bmmmm/claudii) — run `claudii omlx connect`
once to wire it up. While an agent runs, the cc-statusline shows
`⚡ <task> <model-short> <Xs>`. Updates at Claude Code turn boundaries
(real-time view → Console).

`scripts/statusline-omlx.sh` + `scripts/statusline-compose.sh` are kept
as fallbacks for non-claudii setups.

## Admin API

All under `/internal/admin/` — same auth (session cookie or
`X-Admin-Token` header) as the rest of the admin endpoints.

| Method | Path | What |
|--------|------|------|
| `GET`  | `/internal/admin/agents` | `{active, recent, routing, bench, usage, omlx_status}` for the Console |
| `POST` | `/internal/admin/agents/bench` | Body `{force:bool}` — fires `scripts/agent-bench` via compose-ctl. 202 on start, 409 if already running |
| `POST` | `/internal/admin/models` | Body `{action:"load"\|"unload", model:"<id>"}` — proxies to oMLX. Model id validated against `[A-Za-z0-9._-]+` |
| `GET`  | `/internal/admin/diagnostics?include=agents` | omlx connectivity, file sizes, bench freshness, smart-skip log |

## Files

| File | Role |
|------|------|
| `scripts/agent` | Wrapper — POSTs simple tasks to gateii→omlx, mkdir-lock, writes active.json + log.jsonl |
| `scripts/agent-bench` | Self-adapting benchmark — discovers loaded models, evicts to fit memory budget, smart-skip |
| `scripts/statusline-omlx.sh`, `scripts/statusline-compose.sh` | Optional cc-statusline indicator + composer for non-claudii setups |
| `config/openresty/lua/providers/omlx.lua` | oMLX provider — Anthropic-format upstream, sums input + cache_creation + cache_read tokens |
| `config/openresty/html/console/agents.html` | Console "Agents" tab |
| `config/openresty/html/console/static/agents.js` | 2-s polling + render logic |
| `data/agents/active.json` | Currently-running agent (omitted if idle) — gitignored |
| `data/agents/log.jsonl` | Append-only per-call history — gitignored |
| `data/agents/routing.json` | Bench-picked `(model, max_tokens)` per task — gitignored |
| `data/agents/bench-results.json` | Full per-trial data — gitignored |

## Configuration

In `.env` (see `.env.example`):

```bash
OMLX_URL=http://host.docker.internal:8000   # default — points proxy/compose-ctl at the Mac host
OMLX_API_KEY=<min 4 chars>                   # set in oMLX admin UI; can be a dummy if you toggle
                                             #   "Skip API key verification" for localhost-only use
```

Both vars are read by the `gateii-proxy` and `gateii-compose-ctl`
containers. Wrapper scripts running on the host pick up `OMLX_API_KEY`
from `.env` directly.

## Known limitations

- **cc-statusline lags real-time** — the Claude Code `statusLine` command
  only re-renders at turn boundaries. The Console tab is the real-time
  source (2 s poll).
- **Big-model load + bench** — when oMLX is loading a 20 GB model, it
  may briefly refuse new connections; bench's `/v1/models/status` calls
  can fail mid-run. Workaround: pre-load the big model via the Console
  before triggering Force re-run.
- **Multi-step reasoning, math, complex code review** — empirically these
  fail on Qwen3.5-9B (with thinking disabled) and the bigger gemma is too
  slow. The CLAUDE.md routing rule excludes them — keep these on Claude.
