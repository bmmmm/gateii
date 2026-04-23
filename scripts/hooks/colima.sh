#!/bin/bash
# colima.sh — pre-up hook for macOS + Colima
#
# Ensures the Colima VM is running and exports DOCKER_HOST to the Colima
# socket. This hook is SOURCED by up.sh (not executed), so `export` lines
# below persist into up.sh's subsequent `docker` calls.
#
# Enable by setting in .env:
#   GATEII_PREUP_HOOK=scripts/hooks/colima.sh
#
# Requirements: macOS, `colima` installed (brew install colima).

GRN='\033[0;32m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'

if [ "$(uname)" != "Darwin" ]; then
    echo -e "  ${RED}✗${NC} colima.sh hook is macOS-only (uname: $(uname))" >&2
    return 1 2>/dev/null || exit 1
fi

if ! command -v colima >/dev/null 2>&1; then
    echo -e "  ${RED}✗${NC} colima not installed" >&2
    echo -e "  ${DIM}    brew install colima${NC}" >&2
    return 1 2>/dev/null || exit 1
fi

# colima status returns 0 when running, non-zero when stopped
if colima status >/dev/null 2>&1; then
    echo -e "  ${GRN}✓${NC} Colima already running"
else
    echo -e "  ${DIM}Colima not running — starting...${NC}"
    if ! colima start; then
        echo -e "  ${RED}✗${NC} colima start failed" >&2
        echo -e "  ${DIM}    Try: colima start --verbose${NC}" >&2
        return 1 2>/dev/null || exit 1
    fi
    echo -e "  ${GRN}✓${NC} Colima started"
fi

# Point docker CLI at the Colima socket for the rest of up.sh.
COLIMA_SOCK="$HOME/.colima/default/docker.sock"
if [ -S "$COLIMA_SOCK" ] && [ -z "${DOCKER_HOST:-}" ]; then
    export DOCKER_HOST="unix://$COLIMA_SOCK"
fi
