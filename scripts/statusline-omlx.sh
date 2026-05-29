#!/bin/bash
# scripts/statusline-omlx.sh — Claude Code statusLine hook
#
# Reads data/agents/active.json (if present) and prints a one-line indicator
# that Claude Code shows above the prompt while a local omlx-backed agent is
# running. Empty output if no agent active.
#
# Install in ~/.claude/settings.json:
#   "statusLine": {
#     "type": "command",
#     "command": "~/offline_coding/gateii/scripts/statusline-omlx.sh"
#   }
#
# Performance: file read only, no network. Sub-5ms typical.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTIVE="$SCRIPT_DIR/../data/agents/active.json"
[ -f "$ACTIVE" ] || exit 0

JQ=/opt/homebrew/bin/jq
[ -x "$JQ" ] || JQ=jq

# If active.json is older than 5 min, probably a stale crash leftover — ignore
NOW=$(/bin/date +%s)
STARTED=$($JQ -r '.started_epoch // 0' "$ACTIVE" 2>/dev/null || echo 0)
[ "$STARTED" = "0" ] && exit 0
ELAPSED=$((NOW - STARTED))
[ "$ELAPSED" -gt 300 ] && exit 0

TASK=$($JQ -r '.task // "?"' "$ACTIVE" 2>/dev/null)
MODEL=$($JQ -r '.model // "?"' "$ACTIVE" 2>/dev/null)
# Compact model name (drop -MLX-4bit etc.)
MODEL_SHORT=$(printf '%s' "$MODEL" | /usr/bin/sed -E 's/-MLX-4bit$//; s/-A3B-4bit$/-A3B/; s/-a4b-it-4bit$//')

printf '⚡ omlx %s • %s • %ds\n' "$TASK" "$MODEL_SHORT" "$ELAPSED"
