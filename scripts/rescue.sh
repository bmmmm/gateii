#!/bin/bash
# rescue.sh — emergency recovery when the gateii proxy is broken
#
# What it does:
#   1. Removes ANTHROPIC_BASE_URL from ~/.claude/settings.json (direct Anthropic)
#   2. Restarts the gateii-proxy container
#
# Usage:
#   ./scripts/rescue.sh            — switch direct + restart proxy
#   ./scripts/rescue.sh --no-restart  — only switch direct (if Docker is also broken)
#
# After running: restart Claude Code, then test the fix, then:
#   ./scripts/admin.sh switch local

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
NO_RESTART="${1:-}"

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

echo ""
echo -e "${BOLD}gateii rescue${NC}"
echo ""

# ── Step 1: Switch to direct Anthropic ────────────────────────────────────────
if [ ! -f "$CLAUDE_SETTINGS" ]; then
    echo -e "  ${RED}✗${NC} Claude settings not found at $CLAUDE_SETTINGS" >&2
    exit 1
fi

TMP="${CLAUDE_SETTINGS}.rescue.tmp"
python3 - "$CLAUDE_SETTINGS" "$TMP" <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    d = json.load(f)
removed = d.get('env', {}).pop('ANTHROPIC_BASE_URL', None)
with open(dst, 'w') as f:
    json.dump(d, f, indent=2)
    f.write('\n')
print('removed' if removed else 'already_direct')
PYEOF

if [ $? -eq 0 ] && mv "$TMP" "$CLAUDE_SETTINGS"; then
    echo -e "  ${GRN}✓${NC} Switched to direct Anthropic"
    echo -e "  ${DIM}  → Restart Claude Code now to reconnect${NC}"
else
    rm -f "$TMP"
    echo -e "  ${RED}✗${NC} Failed to update $CLAUDE_SETTINGS" >&2
    exit 1
fi

echo ""

# ── Step 2: Restart proxy container ───────────────────────────────────────────
if [ "$NO_RESTART" = "--no-restart" ]; then
    echo -e "  ${DIM}Skipping container restart (--no-restart)${NC}"
    echo ""
else
    # Auto-detect Colima socket
    if [ -z "${DOCKER_HOST:-}" ]; then
        COLIMA_SOCK="$HOME/.colima/default/docker.sock"
        [ -S "$COLIMA_SOCK" ] && export DOCKER_HOST="unix://$COLIMA_SOCK"
    fi

    echo -e "  Restarting gateii-proxy..."
    if docker compose -f "$PROJECT_DIR/docker-compose.yml" restart gateii-proxy 2>/dev/null; then
        echo -e "  ${GRN}✓${NC} Proxy container restarted"
        # Quick health check
        sleep 2
        if docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T gateii-proxy \
            wget -qO- http://127.0.0.1:8080/health >/dev/null 2>&1; then
            echo -e "  ${GRN}✓${NC} Proxy is healthy"
        else
            echo -e "  ${YEL}⚠${NC}  Proxy restarted but health check failed — check logs:"
            echo -e "  ${DIM}  docker logs gateii-proxy --tail=20${NC}"
        fi
    else
        echo -e "  ${YEL}⚠${NC}  Could not restart proxy (Docker unavailable or stack not running)"
        echo -e "  ${DIM}  Start manually: DOCKER_CONTEXT=colima docker compose up -d${NC}"
    fi
    echo ""
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "  ${DIM}1. Restart Claude Code (picks up direct Anthropic connection)${NC}"
echo -e "  ${DIM}2. Fix the proxy issue, then reload: docker exec gateii-proxy openresty -s reload${NC}"
echo -e "  ${DIM}3. Switch back: $SCRIPT_DIR/admin.sh switch local${NC}"
echo ""
