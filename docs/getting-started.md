# Getting started

## Requirements

- Docker + Docker Compose (Linux native, Docker Desktop, Colima, Rancher
  Desktop, OrbStack — any engine works)
- `jq` (for the admin CLI)
- `curl` (for health checks and the smoke test)

Optional but recommended:

- [claudii](https://github.com/bmmmm/claudii) for active-session detection
  before routing switches

## 1. Clone and configure

```bash
git clone https://github.com/bmmmm/gateii
cd gateii
cp .env.example .env
```

Edit `.env`:

- `PROXY_MODE` — `passthrough` (default, forwards the client's own key) or
  `apikey` (gateii holds the upstream key, issues proxy keys to users).
- `PASSTHROUGH_USER` — label shown in Grafana when running passthrough.
- If on macOS with Colima, also set:
  ```ini
  GATEII_PREUP_HOOK=scripts/hooks/colima.sh
  ```
  See [hook docs](../scripts/hooks/README.md) for other runtimes.

## 2. Install the CLI wrapper (optional but recommended)

```bash
# Add to ~/.zshrc or ~/.bashrc
alias gateii='~/offline_coding/gateii/scripts/gateii'
```

Or symlink into PATH:

```bash
ln -s "$(pwd)/scripts/gateii" ~/.local/bin/gateii
```

From now on, `gateii <subcommand>` works from any directory. Full reference:
[CLI](cli.md).

## 3. Start the stack

```bash
gateii up
```

This:

1. Runs `GATEII_PREUP_HOOK` if set (e.g. `colima start`).
2. Runs `docker compose up -d`.
3. Waits for `/health` to respond.
4. Shows active Claude Code sessions (via `claudii`) so you know whether
   it's safe to route through gateii.

## 4. Point Claude Code at gateii

```bash
gateii switch local-proxy
```

This sets `ANTHROPIC_BASE_URL` in `~/.claude/settings.json`. Restart Claude
Code to pick it up.

## 5. Open the dashboard

```bash
open http://localhost:3001
```

Grafana, no login required. The dashboard auto-populates as requests flow
through the proxy.

## Boot after reboot

On a fresh boot:

```bash
gateii up                    # restores the VM if needed + starts containers
gateii sessions              # check what's running — wait if you see active work
gateii switch local-proxy    # switch when safe
```

Or set `GATEII_AUTO_SWITCH=1` in `.env` to let `gateii up` auto-switch
whenever no Claude Code session is active.

## Next steps

- [Routing modes](routing.md) — local-proxy / remote-proxy / direct, safe
  dev workflow, emergency rescue.
- [Modes](modes.md) — passthrough vs apikey, when to use each.
- [Configuration](configuration.md) — all `.env` variables.
- [Monitoring](monitoring.md) — what the Grafana dashboard shows.
