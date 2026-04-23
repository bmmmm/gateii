# Monitoring

Grafana at `http://localhost:3001`, no login required. Dashboard
auto-provisioned from `config/grafana/provisioning/`.

## What the dashboard shows

### Overview — requests, tokens, cost

![Requests, tokens, cost overview](dashboard-overview.png)

Top-level KPIs for the current billing cycle:

- Total requests, tokens (input + output), cost
- Per-user breakdown
- Current rate (requests/min)

### Per-model breakdown

![Token and cost breakdown per model](dashboard-models.png)

For each model used:

- Tokens in vs. out
- Cost per model (driven by `providers.json` pricing)
- Request distribution

Useful for spotting when a single model dominates spend.

### Health — errors, stop reasons, latency

![Error rate, stop reasons, request rate](dashboard-health.png)

- Error rate (non-200 upstream responses)
- Stop-reason distribution (`end_turn`, `max_tokens`, `tool_use`, …) —
  a spike in `max_tokens` often signals a prompt that needs a larger
  output budget
- p50 / p95 latency over time

## Metrics exposed

Prometheus scrape endpoint: `http://localhost:8888/metrics`

| Metric | Labels | What it tells you |
|--------|--------|-------------------|
| `gateii_tokens_total` | user, provider, model, type | Input/output tokens consumed |
| `gateii_cost_dollars_total` | user, provider, model, type | Estimated cost (active provider pricing) |
| `gateii_requests_total` | user, provider, model | Request count |
| `gateii_request_duration_ms_total` | user, provider, model | Cumulative latency (/ requests = avg) |
| `gateii_upstream_errors_total` | user, provider, model | Non-200 upstream responses |
| `gateii_stop_reason_total` | user, provider, model, reason | `end_turn` / `max_tokens` / `tool_use` |
| `gateii_user_blocked` | user | 1 if user is currently blocked |

The `type` label on `gateii_tokens_total` distinguishes input, output,
cache-write, and cache-read tokens separately — useful when evaluating
prompt-caching effectiveness.

## How cost is calculated

Cost is computed in `metrics.lua` from the token counts, using the pricing
in `config/openresty/lua/providers.json`. The `active_provider` entry
selects which pricing table drives `gateii_cost_dollars_total`.

For Anthropic prompt-caching, the per-token price is multiplied by:

- `cache_write_multiplier` (default 1.25)
- `cache_read_multiplier` (default 0.1)

Edit `providers.json` to adjust prices — no rebuild needed, just
`gateii reload`.

Full details: [configuration.md](configuration.md).

## Prometheus retention

Default: unlimited. Override in `.env`:

```ini
HISTORY_RETENTION=90d   # or 30d, 180d, 365d
```

Counters in nginx shared dicts don't survive container restarts, but
Prometheus keeps the time series — so restarts lose seconds of data, not
history.

## Console plugin

Opt-in admin UI at `/console` for key management, per-user limits, and live
pricing comparison. Enable:

```bash
gateii admin plugin enable console
```

See [plugins.md](plugins.md) for details.

## Accessing Prometheus directly

The console queries Prometheus via a reverse proxy at `/internal/prometheus/`
(restricted to localhost and the Docker network). This avoids CORS issues
when the browser fetches historical data.

For ad-hoc queries: Prometheus UI at `http://localhost:9090` (binding
controlled by `PROMETHEUS_BIND` in `.env`, default `127.0.0.1`).

## Health endpoint

`GET /internal/admin/health` returns component reachability — proxy,
Prometheus, Grafana (parallel checks), plus upstream error rate from
counters. Used by the console health bar and external monitors.
