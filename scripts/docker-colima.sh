#!/bin/bash
# docker-colima.sh — docker wrapper that auto-detects Colima socket
#
# Usage: scripts/docker-colima.sh <docker args>
# Example: scripts/docker-colima.sh exec gateii-proxy openresty -s reload
#          scripts/docker-colima.sh compose up -d
#          scripts/docker-colima.sh ps --format "{{.Names}}: {{.Status}}"
#
# Why: Colima uses a non-standard socket path that Claude Code's sandbox blocks.
# This wrapper is added to settings.local.json as a single allowed pattern,
# replacing the many DOCKER_CONTEXT/DOCKER_HOST variations.

if [ -z "${DOCKER_HOST:-}" ]; then
    COLIMA_SOCK="$HOME/.colima/default/docker.sock"
    [ -S "$COLIMA_SOCK" ] && export DOCKER_HOST="unix://$COLIMA_SOCK"
fi

exec docker "$@"
