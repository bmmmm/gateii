# gateii

A minimal, self-hosted proxy for the Anthropic Claude API.
Runs on any Docker host. No cloud, no signup, no SaaS.

```
Claude Code / your app
        │
        ▼
  gateii :8888   ←  token tracking · rate limiting · monitoring
        │
        ▼
  api.anthropic.com
```

## Why gateii exists

You're paying for Claude and have no idea what's actually happening. Either
your team shares one API key with no visibility, or every user has their
own and finance reviews a spreadsheet of charges no one can attribute. If
you're on the Max plan and occasionally hit the wall, you have no data on
where it went.

| Problem | gateii answer |
|---------|---------------|
| No visibility into token usage | Per-user, per-model counters in a Grafana dashboard |
| Sharing one API key is risky | Per-user proxy keys pinned to their own provider + credential |
| Don't want another SaaS | Self-hosted, stateless, three Docker containers, no external deps |
| Claude Max plan (OAuth) | `passthrough` mode — your token forwarded as-is, no server key |
| Accidental runaway spend | Per-user daily limits, auto-block until midnight UTC |
| Cost discussions without data | Historical metrics in Prometheus, cost estimates from `providers.json` |

Unlike managed observability tools, gateii runs locally, stores nothing on
third-party infrastructure, and keeps your Anthropic key where you already
put it (in your `.env` or your OAuth session).

## Quickstart

```bash
git clone https://github.com/bmmmm/gateii
cd gateii
cp .env.example .env

# Optional: alias the CLI so `gateii <subcommand>` works from anywhere
echo "alias gateii='$(pwd)/scripts/gateii'" >> ~/.zshrc && source ~/.zshrc

# Start the stack
gateii up

# Point Claude Code at the proxy
gateii switch local-proxy

# Optional: remind yourself when a Claude Code session is NOT routed through gateii
gateii hook install

# Open the dashboard
open http://localhost:3001
```

The `gateii hook install` step registers a `UserPromptSubmit` hook in
`~/.claude/settings.json` that warns (up to 3× per session) when
`ANTHROPIC_BASE_URL` is not pointed at this gateii. It is opt-in on purpose —
it only makes sense once you actively route Claude Code through gateii. Remove
it with `gateii hook uninstall`. If you manage `~/.claude/settings.json` via
dotfiles, mirror the entry there too.

Full walkthrough: [Getting started](docs/getting-started.md).

## Docs

| Page | What's in it |
|------|--------------|
| [Getting started](docs/getting-started.md) | Install prerequisites, first start, boot after reboot |
| [CLI reference](docs/cli.md) | All `gateii <subcommand>` options |
| [Modes](docs/modes.md) | `passthrough` vs `apikey`, when to use each |
| [Routing](docs/routing.md) | `local-proxy` / `remote-proxy` / `direct`, safe dev workflow, emergency rescue |
| [Monitoring](docs/monitoring.md) | What the Grafana dashboard shows, metrics exposed |
| [Configuration](docs/configuration.md) | All `.env` variables, `providers.json` pricing |
| [Plugins](docs/plugins.md) | `console` (web UI) and `git-tracking` |
| [Local agents (omlx)](docs/agents.md) | Route simple tasks (commits, summaries, …) to a local Apple-Silicon LLM |
| [Providers](docs/providers.md) | Adding a new upstream provider |
| [Architecture](docs/architecture.md) | Three containers, shared dicts, why no Redis |
| [Security](docs/security.md) | Admin API hardening, secrets hygiene, network exposure |
| [keys.json schema](docs/keys.md) | Structured key storage (`apikey` mode) |
| [Bootstrap handshake](docs/bootstrap.md) | Self-provisioning keys over HMAC |
| [Admin API](docs/admin-api.md) | HTTP endpoint reference |

Also: [Pre-up hooks](scripts/hooks/README.md) — how to run
platform-specific setup (Colima, podman, …) before `docker compose up`.

## Stack at a glance

| Container | Image | Port | Role |
|-----------|-------|------|------|
| `gateii-proxy` | `openresty/openresty:alpine` | 8888 | nginx + LuaJIT proxy + metrics |
| `gateii-prometheus` | `prom/prometheus` | 9090 | metrics storage |
| `gateii-grafana` | `grafana/grafana` | 3001 | dashboard |
| `gateii-git-tracking` | `alpine` _(plugin)_ | — | git activity metrics (optional) |

All state lives in nginx shared memory. Prometheus stores the time series —
so the proxy itself is effectively stateless between restarts. See
[architecture.md](docs/architecture.md).

## License

[GPL-3.0](LICENSE)
