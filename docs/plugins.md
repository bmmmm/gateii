# Plugins

Opt-in features that ship with the repo but aren't active by default.
Managed via `gateii admin plugin`:

```bash
gateii admin plugin list              # show all plugins + status
gateii admin plugin enable <name>     # activate
gateii admin plugin disable <name>    # deactivate
gateii admin plugin status            # detailed status
```

## Available plugins

| Plugin | What it does | Enable |
|--------|-------------|--------|
| `console` | Admin web console at `/console` — key management, limits, usage bars, live stats, live pricing comparison, monthly cost forecast. | `gateii admin plugin enable console` |
| `git-tracking` | Track git activity (commits, lines changed) alongside token usage. Useful for correlating spend with coding output. | `gateii admin plugin enable git-tracking ~/projects ~/servers` |

Both can be toggled independently without affecting the core proxy or
each other.

## console

Web UI served at `http://localhost:8888/console`. Same origin as the
proxy — no CORS dance.

What it adds:

- Key management (issue, revoke, rotate) without shelling out
- Per-user block / unblock / daily limit controls
- Live usage bars and rate indicators
- Pricing comparison panel pulling live top-weekly programming models from
  OpenRouter (12 h cache in shared dicts)
- Monthly cost forecast based on rolling average

Auth: uses the `admin_session` cookie issued by `POST /internal/admin/login`.
Token is `ADMIN_TOKEN` from `.env`. No separate password.

Activation:

```bash
gateii admin plugin enable console
```

This sets `CONSOLE_ENABLED=1` in `.env` and reloads the proxy. No extra
container needed.

## git-tracking

Separate container (Docker Compose profile). Scans mounted repo paths
and writes Prometheus metrics to `/data/git-metrics.txt`, which
Prometheus scrapes alongside the proxy metrics.

Activation:

```bash
gateii admin plugin enable git-tracking ~/projects ~/servers
```

Config in `.env`:

```ini
GIT_TRACKING_ENABLED=1
GIT_AUTHOR=alice              # filter commits by author (optional)
GIT_TRACKING_INTERVAL=300     # refresh every 5 min
```

The paths you pass on the CLI are written to `docker-compose.override.yml`
as bind mounts. Re-run `enable` with different paths to update the list.

Metrics exposed:

| Metric | Labels | What it tells you |
|--------|--------|-------------------|
| `git_commits_total` | repo, author | Commit count |
| `git_lines_added_total` | repo, author, language | Lines added |
| `git_lines_deleted_total` | repo, author, language | Lines deleted |

Use in Grafana to overlay "tokens consumed" with "lines of code produced"
— a rough but revealing efficiency metric.

## Disable

```bash
gateii admin plugin disable console
gateii admin plugin disable git-tracking
```

Flips the `*_ENABLED` flag in `.env` and runs the appropriate compose
reload / down. Data (metrics history, `data/keys.json`, etc.) is kept
regardless.
