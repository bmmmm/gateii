#!/bin/bash
# scripts/statusline-compose.sh — Claude Code statusLine composer
#
# Wraps an existing statusLine command (default: claudii-sessionline) and
# prepends an omlx-agent indicator when a local agent is currently running.
#
# Install in ~/.claude/settings.json:
#   "statusLine": {
#     "type": "command",
#     "command": "/Users/bma/offline_coding/gateii/scripts/statusline-compose.sh"
#   }
#
# Override the inner command via env (in settings.json):
#   "env": { "STATUSLINE_INNER": "your-other-statusline-cmd" }
#
# Behavior:
#   - omlx active  → prints  "<omlx-indicator> │ <inner-output>"
#   - omlx idle    → prints  "<inner-output>"             (no change)
#   - inner missing→ prints  "<omlx-indicator>"  or empty (graceful)

set -e

INNER_CMD="${STATUSLINE_INNER:-claudii-sessionline}"
OMLX_HOOK="/Users/bma/offline_coding/gateii/scripts/statusline-omlx.sh"

# Capture the JSON Claude Code sends on stdin (model, cwd, etc.)
INPUT=$(/bin/cat)

# Run inner command with the same stdin
INNER_OUT=""
if /usr/bin/command -v "$INNER_CMD" >/dev/null 2>&1; then
    INNER_OUT=$(printf '%s' "$INPUT" | "$INNER_CMD" 2>/dev/null || true)
fi

# omlx indicator (no stdin needed; reads data/agents/active.json)
OMLX_OUT=""
if [ -x "$OMLX_HOOK" ]; then
    OMLX_OUT=$("$OMLX_HOOK" 2>/dev/null || true)
fi

# Compose
if [ -n "$OMLX_OUT" ] && [ -n "$INNER_OUT" ]; then
    printf '%s │ %s\n' "$OMLX_OUT" "$INNER_OUT"
elif [ -n "$OMLX_OUT" ]; then
    printf '%s\n' "$OMLX_OUT"
elif [ -n "$INNER_OUT" ]; then
    printf '%s\n' "$INNER_OUT"
fi
