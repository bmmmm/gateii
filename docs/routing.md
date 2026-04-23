# Routing

How Claude Code's traffic reaches Anthropic — and how to switch between
paths without interrupting active work.

## Three routes

```
                                    ┌── local-proxy ── localhost:8888 ── Anthropic
Claude Code ── ~/.claude/settings ──┼── remote-proxy ── your.server:8888 ── Anthropic
                                    └── direct ─────────────────────────── Anthropic
```

The route is controlled by `ANTHROPIC_BASE_URL` in
`~/.claude/settings.json`. `gateii switch` rewrites that file.

| Target | What happens |
|--------|--------------|
| `local-proxy` | `ANTHROPIC_BASE_URL=http://localhost:8888`. Health-checked first — refuses to switch if the local proxy isn't responding. |
| `remote-proxy` | `ANTHROPIC_BASE_URL=$REMOTE_URL` (from `.env`). Health-checked against the remote first. |
| `direct` | `ANTHROPIC_BASE_URL` removed entirely. Claude Code goes straight to Anthropic. |
| `status` | Shows the current value, doesn't change anything. |

## Switching safely

`gateii switch` does **not** automatically check for active Claude Code
sessions — that check is up to you, via `gateii sessions` (which wraps
`claudii se`). Why: a switch mid-stream can cut a response in half, and
only you know whether the current work is worth preserving.

Typical flow:

```bash
gateii sessions              # see what's running
# if active:
#   ° wait, or let it finish
#   ° or force-switch knowing you'll cut it
gateii switch local-proxy    # when safe
# restart Claude Code for the new base URL to take effect
```

Opt-in auto-switch: set in `.env`:

```ini
GATEII_DEFAULT_ROUTE=local-proxy
GATEII_AUTO_SWITCH=1
```

Then `gateii up` auto-runs `switch local-proxy` **only** when no Claude
Code session has been active in the last 30 seconds. Requires `claudii`
for session detection.

## Safe dev workflow for proxy changes

When editing Lua or nginx config, switch to direct first so a broken proxy
doesn't cut off Claude Code:

```bash
gateii switch direct         # 1. go direct — Claude Code stays connected
# edit Lua / nginx config
gateii reload                # 2. openresty -s reload (no container restart)
# test the fix
gateii switch local-proxy    # 3. back to proxy when satisfied
```

Why this order matters: if step 2 fails silently and the proxy returns 500s,
step 3's health check will refuse to switch — so you'll notice
immediately, before Claude Code errors out.

## Emergency rescue

If the proxy is broken and Claude Code is already cut off:

```bash
gateii rescue
```

This:

1. Removes `ANTHROPIC_BASE_URL` from `~/.claude/settings.json` (→ direct).
2. Restarts the `gateii-proxy` container.

After running: restart Claude Code, then fix the proxy issue, then
`gateii switch local-proxy` to come back.

If Docker itself is down (e.g., Colima VM crashed), skip the restart step:

```bash
gateii rescue --no-restart
# or directly: scripts/rescue.sh --no-restart
```

## Operational rules

- **Always `switch direct` before stopping the stack.** Otherwise Claude
  Code keeps trying to reach a dead proxy and errors out.
- **Start stack → switch local-proxy.** Never switch to a proxy that isn't
  running — the health check will refuse, but confusingly.
- **Restart Claude Code after every switch.** It reads settings only at
  startup. The CLI reminds you.
