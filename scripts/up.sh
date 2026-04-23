#!/bin/bash
# up.sh — start the gateii stack
#
# Platform-agnostic by default. If you need platform-specific setup before
# `docker compose up` (e.g. starting a container runtime VM), set
# GATEII_PREUP_HOOK in .env to the path of a hook script. See
# scripts/hooks/README.md for the contract and shipped examples.
#
# Steps:
#   1. Source .env (optional)
#   2. Run the pre-up hook if GATEII_PREUP_HOOK is set (e.g. Colima autostart)
#   3. Verify Docker daemon is reachable
#   4. docker compose up -d
#   5. Wait for /health
#   6. Show active Claude Code sessions if `claudii` is installed (optional)
#
# What it does NOT do:
#   - Auto-switch Claude Code routing by default. Set GATEII_DEFAULT_ROUTE
#     (local-proxy|remote-proxy|direct) in .env to show a personalized hint,
#     and GATEII_AUTO_SWITCH=1 to actually switch when no Claude Code session
#     has been active in the last 30s.
#
# Usage:
#   ./scripts/up.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'; CYN='\033[0;36m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

echo ""
echo -e "${BOLD}gateii up${NC}"
echo ""

# ── Step 1: Load .env (optional) ──────────────────────────────────────────────
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a; source "$PROJECT_DIR/.env"; set +a
fi

# ── Step 2: Pre-up hook (optional, platform-specific) ─────────────────────────
# Hooks are SOURCED (not executed) so that env exports like DOCKER_HOST
# persist into this script's Docker calls. See scripts/hooks/README.md.
if [ -n "${GATEII_PREUP_HOOK:-}" ]; then
    HOOK_PATH="$GATEII_PREUP_HOOK"
    [[ "$HOOK_PATH" != /* ]] && HOOK_PATH="$PROJECT_DIR/$HOOK_PATH"

    if [ ! -f "$HOOK_PATH" ]; then
        echo -e "  ${RED}✗${NC} GATEII_PREUP_HOOK points to missing file: $HOOK_PATH" >&2
        exit 1
    fi

    echo -e "  ${DIM}Running pre-up hook: ${GATEII_PREUP_HOOK}${NC}"
    # shellcheck disable=SC1090
    source "$HOOK_PATH"
fi

# ── Step 3: Docker availability ───────────────────────────────────────────────
if ! docker version >/dev/null 2>&1; then
    echo -e "  ${RED}✗${NC} Docker daemon not reachable" >&2
    echo -e "  ${DIM}  On macOS with Colima: set GATEII_PREUP_HOOK=scripts/hooks/colima.sh in .env${NC}" >&2
    echo -e "  ${DIM}  Otherwise: start your Docker runtime, then re-run this script${NC}" >&2
    exit 1
fi
echo -e "  ${GRN}✓${NC} Docker daemon reachable"

# ── Step 4: Start the stack ───────────────────────────────────────────────────
echo -e "  ${DIM}Running docker compose up -d...${NC}"
if docker compose -f "$PROJECT_DIR/docker-compose.yml" up -d; then
    echo -e "  ${GRN}✓${NC} Stack started"
else
    echo -e "  ${RED}✗${NC} docker compose up failed" >&2
    exit 1
fi

# ── Step 5: Health check ──────────────────────────────────────────────────────
PROXY_PORT="${PROXY_PORT:-8888}"
PROXY_HOST="${PROXY_HOST:-localhost}"
HEALTH_URL="http://${PROXY_HOST}:${PROXY_PORT}/health"

echo -e "  ${DIM}Waiting for ${HEALTH_URL}...${NC}"
attempts=0
until curl -sf --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 15 ]; then
        echo -e "  ${RED}✗${NC} Proxy did not become healthy after 30s" >&2
        echo -e "  ${DIM}  Check logs: docker logs gateii-proxy --tail=30${NC}" >&2
        exit 1
    fi
    sleep 2
done
echo -e "  ${GRN}✓${NC} Proxy healthy at $HEALTH_URL"

# ── Step 6: Active Claude Code sessions (optional, via claudii) ───────────────
echo ""
ACTIVE_COUNT=0
if command -v claudii >/dev/null 2>&1; then
    ACTIVE_COUNT=$(claudii sessions --json 2>/dev/null | jq '[.[] | select(.age_seconds < 30)] | length' 2>/dev/null || echo "0")
    if [ "$ACTIVE_COUNT" -gt 0 ]; then
        echo -e "  ${YEL}⚠${NC}  ${ACTIVE_COUNT} Claude Code session(s) active in the last 30s:"
        claudii sessions --json 2>/dev/null | jq -r '
            .[] | select(.age_seconds < 30) |
            "    \(.age_seconds)s ago  ·  \(.model)  ·  \(.session_id[0:8])"' 2>/dev/null || true
        echo ""
        echo -e "  ${DIM}Switching now may interrupt them mid-stream.${NC}"
        echo -e "  ${DIM}Run ${BOLD}claudii se${NC}${DIM} for full details, then switch when safe.${NC}"
    else
        echo -e "  ${GRN}✓${NC} No active Claude Code sessions — safe to switch"
    fi
fi

# ── Step 7: Optional auto-switch ──────────────────────────────────────────────
# Only runs when the user opts in via .env AND no Claude session is active.
AUTO_SWITCHED=0
if [ -n "${GATEII_DEFAULT_ROUTE:-}" ] && [ "${GATEII_AUTO_SWITCH:-0}" = "1" ]; then
    if ! command -v claudii >/dev/null 2>&1; then
        echo ""
        echo -e "  ${DIM}GATEII_AUTO_SWITCH=1 requires claudii for session detection — skipping${NC}"
    elif [ "$ACTIVE_COUNT" -gt 0 ]; then
        echo ""
        echo -e "  ${DIM}GATEII_AUTO_SWITCH=1 but sessions are active — skipping (switch manually when safe)${NC}"
    else
        echo ""
        echo -e "  ${DIM}Auto-switching to ${GATEII_DEFAULT_ROUTE}...${NC}"
        if "$SCRIPT_DIR/admin.sh" switch "$GATEII_DEFAULT_ROUTE"; then
            AUTO_SWITCHED=1
        else
            echo -e "  ${RED}✗${NC} Auto-switch failed — run ${BOLD}admin.sh switch ${GATEII_DEFAULT_ROUTE}${NC}${RED} manually${NC}" >&2
        fi
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
ROUTE="${GATEII_DEFAULT_ROUTE:-local-proxy}"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
if [ "$AUTO_SWITCHED" = "1" ]; then
    echo -e "  ${DIM}1. Restart Claude Code to pick up the new route${NC}"
    echo -e "  ${DIM}2. Dashboard:${NC}              ${CYN}open http://localhost:3001${NC}"
elif command -v claudii >/dev/null 2>&1; then
    echo -e "  ${DIM}1. Check active sessions:${NC}  ${CYN}gateii sessions${NC}"
    echo -e "  ${DIM}2. When safe, switch:${NC}      ${CYN}gateii switch ${ROUTE}${NC}"
    echo -e "  ${DIM}3. Dashboard:${NC}              ${CYN}open http://localhost:3001${NC}"
else
    echo -e "  ${DIM}1. Switch Claude Code:${NC}     ${CYN}gateii switch ${ROUTE}${NC}"
    echo -e "  ${DIM}2. Dashboard:${NC}              ${CYN}http://localhost:3001${NC}"
fi
echo ""
