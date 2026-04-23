# CLI reference — `gateii`

`scripts/gateii` is the user-facing dispatcher. It wraps `scripts/up.sh`,
`scripts/admin.sh`, `scripts/rescue.sh`, and direct docker calls behind a
single entry point.

## Installation

Pick one:

```bash
# Alias
alias gateii='~/offline_coding/gateii/scripts/gateii'

# Symlink into PATH
ln -s "$(pwd)/scripts/gateii" ~/.local/bin/gateii
```

Both work. Alias is faster to set up; symlink survives shell reloads without
sourcing `.zshrc`/`.bashrc`.

## Subcommands

### Stack

| Command | What it does |
|---------|-------------|
| `gateii up` | Start the stack. Runs `GATEII_PREUP_HOOK` first if set. Waits for `/health`. Shows active Claude Code sessions. |
| `gateii down` | `docker compose down`. Volumes are kept. |
| `gateii restart [service]` | Restart all or one service. |
| `gateii reload` | `openresty -s reload` inside the proxy container. Use after editing Lua or nginx config. |
| `gateii logs [service]` | Tail logs. Default: `gateii-proxy`. |
| `gateii smoke` | Run `scripts/smoke-test.sh`. |

### Claude Code routing

| Command | What it does |
|---------|-------------|
| `gateii switch local-proxy` | Route Claude Code through this machine's gateii (`http://localhost:8888`). Checks `/health` first. |
| `gateii switch remote-proxy` | Route through a remote gateii instance (requires `REMOTE_URL` in `.env`). |
| `gateii switch direct` | Bypass the proxy, go straight to Anthropic. Safe to stop the proxy after. |
| `gateii switch status` | Show the current `ANTHROPIC_BASE_URL` from `~/.claude/settings.json`. |
| `gateii sessions` | Passthrough to `claudii sessions` — list active Claude Code sessions. Requires [claudii](https://github.com/bmmmm/claudii). |

Full routing guide: [routing.md](routing.md).

### Admin

| Command | What it does |
|---------|-------------|
| `gateii status` | Combined view: key count, blocked users, current route. |
| `gateii admin <args>` | Passthrough to `scripts/admin.sh`. Use for key management (`add`, `revoke`, `rotate`), blocking (`block`, `unblock`, `limit`), plugins (`plugin list|enable|disable`), and bootstrap (`bootstrap create`). |
| `gateii rescue` | Emergency: switch direct + restart proxy. Use when the proxy is broken and Claude Code is cut off. |

Key management: run `gateii admin help` for the full subcommand list.

### Misc

| Command | What it does |
|---------|-------------|
| `gateii version` | Git commit + tag of the current checkout. |
| `gateii help` | Subcommand list. |

## Exit codes

- `0` — success
- `1` — unknown subcommand, or any wrapped script exited non-zero

The dispatcher uses `exec` where possible, so the wrapped script's exit
code is what you see.

## Design

The dispatcher itself is thin — about 100 lines of bash. It's a mapping
from subcommand to script, not a re-implementation. Use the underlying
scripts directly when you need finer control (e.g., `scripts/admin.sh
plugin enable console --with-token`).
