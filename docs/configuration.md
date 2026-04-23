# Configuration

All configuration via `.env` at the repo root. Example defaults in
`.env.example` — copy and edit:

```bash
cp .env.example .env
```

## Core

| Variable | Default | Description |
|----------|---------|-------------|
| `PROXY_MODE` | `passthrough` | `passthrough` or `apikey`. See [modes.md](modes.md). |
| `PASSTHROUGH_USER` | _(key suffix)_ | Display name in passthrough mode (shown in Grafana). |
| `ANTHROPIC_API_KEY` | — | Required when `PROXY_MODE=apikey`. |
| `ADMIN_TOKEN` | — | ≥ 32 random hex bytes. Required in `apikey` mode (fail-closes the admin API otherwise). |

## Startup (`gateii up`)

| Variable | Default | Description |
|----------|---------|-------------|
| `GATEII_PREUP_HOOK` | unset | Path to a script sourced before `docker compose up`. See [hook docs](../scripts/hooks/README.md). |
| `GATEII_DEFAULT_ROUTE` | unset | `local-proxy` / `remote-proxy` / `direct`. Shown in `gateii up`'s next-steps hint. |
| `GATEII_AUTO_SWITCH` | `0` | If `1` and `GATEII_DEFAULT_ROUTE` is set, `gateii up` auto-switches when no Claude Code session is active. Requires `claudii`. |

## Ports and bindings

| Variable | Default | Description |
|----------|---------|-------------|
| `PROXY_HOST` | `localhost` | Host name used by admin scripts. |
| `PROXY_PORT` | `8888` | Exposed proxy port. |
| `PROXY_BIND` | `127.0.0.1` | Interface to bind to. `0.0.0.0` exposes on LAN — only do this with `ADMIN_TOKEN` set AND real keys in `data/keys.json`. |
| `GRAFANA_PORT` | `3001` | Grafana dashboard. |
| `GRAFANA_BIND` | `127.0.0.1` | Same caveats as `PROXY_BIND`. |
| `PROMETHEUS_BIND` | `127.0.0.1` | Same caveats. |
| `REMOTE_URL` | — | URL of a remote gateii instance, used by `gateii switch remote-proxy`. |

## Data retention

| Variable | Default | Description |
|----------|---------|-------------|
| `HISTORY_RETENTION` | unlimited | Prometheus retention: `30d`, `90d`, `180d`, `365d`, or empty. |
| `COUNTER_RETENTION_DAYS` | `60` | Admin-API user-stats counter retention. |

## Health checks

Used when probing upstream providers from `/internal/admin/health`:

| Variable | Default | Description |
|----------|---------|-------------|
| `HEALTH_CHECK_CONNECT_MS` | `1500` | Connect timeout. |
| `HEALTH_CHECK_SEND_MS` | `1500` | Send timeout. |
| `HEALTH_CHECK_READ_MS` | `3000` | Read timeout. |

Bump these when a provider commonly responds > 3 s.

## Plugins

Manage via `gateii admin plugin list|enable|disable|status <name>`.
Direct `.env` toggles:

| Variable | Default | Description |
|----------|---------|-------------|
| `CONSOLE_ENABLED` | `0` | Admin web console at `/console`. |
| `GIT_TRACKING_ENABLED` | `0` | Git activity metrics container. |
| `GIT_AUTHOR` | — | Filter git-tracking by author name (optional). |
| `GIT_TRACKING_INTERVAL` | `300` | Git-tracking refresh interval (seconds). |

Full plugin docs: [plugins.md](plugins.md).

## Pricing (`providers.json`)

Cost metrics are driven by `config/openresty/lua/providers.json`:

```json
{
  "active_provider": "anthropic",
  "providers": [
    {
      "id": "anthropic",
      "name": "Anthropic (Direct API)",
      "url": "https://www.anthropic.com/pricing",
      "cache_write_multiplier": 1.25,
      "cache_read_multiplier": 0.1,
      "models": [
        { "pattern": "opus",   "name": "Claude Opus 4",    "input": 5.0, "output": 25.0 },
        { "pattern": "sonnet", "name": "Claude Sonnet 4",  "input": 3.0, "output": 15.0 },
        { "pattern": "haiku",  "name": "Claude Haiku 4.5", "input": 1.0, "output": 5.0  }
      ]
    }
  ],
  "comparison_models": [
    {
      "openrouter_id": "anthropic/claude-sonnet-4-6",
      "name": "Claude Sonnet 4.6",
      "vendor": "Anthropic",
      "or_rank": 6,
      "input": 3.0,
      "output": 15.0
    }
  ]
}
```

- `active_provider` selects the pricing table used for `gateii_cost_dollars_total`.
- `cache_write_multiplier` / `cache_read_multiplier` apply to Anthropic
  prompt-caching tokens.
- `comparison_models` is a **static fallback** for the console comparison
  panel. At runtime the console fetches the current top-10 weekly
  programming models from OpenRouter (12 h cache) and replaces this list
  dynamically. `openrouter_id` drives live price lookup; `or_rank` is the
  weekly position badge.

After editing: `gateii reload`.

## Sensitive defaults

- `.env` is `.gitignore`d — never commit real keys. `.env.example` has
  placeholders only.
- `ssl_verify` is `on` — trusted CA certs are installed at container
  startup. Don't flip to `off` without adding your CA to the image.
- Rate limiter is only active in `apikey` mode (needs a server-side key
  to attach limits to). Passthrough has no rate limit — rely on the
  upstream's rate limit instead.
