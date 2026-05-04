#!/bin/sh
# gctl — admin-API helper. Reads ADMIN_TOKEN from .env, logs in once,
# caches the session cookie in /tmp, and proxies subsequent calls.
# Lets Claude (and any operator script) hit /internal/admin/* without
# spelling out the curl + cookie + content-type dance every time.
#
# Usage:
#   ./scripts/gctl.sh session                       — print the session cookie value (for piping)
#   ./scripts/gctl.sh get /internal/admin/diagnostics
#   ./scripts/gctl.sh get  '/internal/admin/diagnostics?include=plugins'
#   ./scripts/gctl.sh post /internal/admin/services/git-tracking/start
#   ./scripts/gctl.sh put  /internal/admin/git-tracking '{"interval":300,"repos":[]}'
#   ./scripts/gctl.sh raw  /metrics                 — no auth, no /internal prefix added
#
# All output is the raw response body. Add `| jq` yourself if you want pretty.

set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${GCTL_HOST:-http://localhost:8888}"
SESSION_FILE="${GCTL_SESSION_FILE:-/tmp/gctl-session-$(id -u)}"
SESSION_TTL=3300  # 55 min — slightly under server's 60 min cookie expiry

die() { echo "gctl: $*" >&2; exit 1; }

read_admin_token() {
    [ -f "$PROJECT_DIR/.env" ] || die "no .env at $PROJECT_DIR/.env"
    tok=$(grep '^ADMIN_TOKEN=' "$PROJECT_DIR/.env" | cut -d= -f2- || true)
    [ -n "$tok" ] || die "ADMIN_TOKEN not set in .env"
    printf '%s' "$tok"
}

session_age() {
    [ -f "$SESSION_FILE" ] || { echo 99999; return; }
    if stat -f %m "$SESSION_FILE" >/dev/null 2>&1; then
        # macOS / BSD
        mtime=$(stat -f %m "$SESSION_FILE")
    else
        # Linux
        mtime=$(stat -c %Y "$SESSION_FILE")
    fi
    echo $(( $(date +%s) - mtime ))
}

login() {
    tok=$(read_admin_token)
    cookie=$(curl -sS -X POST -H "Content-Type: application/json" \
        -d "{\"token\":\"$tok\"}" -i "$HOST/internal/admin/login" \
        | grep -i '^set-cookie:' | sed -n 's/.*admin_session=\([a-f0-9]*\).*/\1/p' || true)
    [ -n "$cookie" ] || die "login failed — admin token rejected or proxy unreachable"
    umask 077
    printf '%s' "$cookie" > "$SESSION_FILE"
    chmod 600 "$SESSION_FILE"
    printf '%s' "$cookie"
}

get_session() {
    age=$(session_age)
    if [ "$age" -gt "$SESSION_TTL" ]; then
        login
    else
        cat "$SESSION_FILE"
    fi
}

cmd_session() {
    get_session
    echo
}

cmd_get() {
    [ $# -ge 1 ] || die "usage: gctl get <path>"
    cookie=$(get_session)
    curl -sS -b "admin_session=$cookie" "$HOST$1"
}

cmd_post() {
    [ $# -ge 1 ] || die "usage: gctl post <path> [json-body]"
    cookie=$(get_session)
    if [ $# -ge 2 ]; then
        curl -sS -X POST -H "Content-Type: application/json" \
            -b "admin_session=$cookie" -d "$2" "$HOST$1"
    else
        curl -sS -X POST -b "admin_session=$cookie" "$HOST$1"
    fi
}

cmd_put() {
    [ $# -ge 2 ] || die "usage: gctl put <path> <json-body>"
    cookie=$(get_session)
    curl -sS -X PUT -H "Content-Type: application/json" \
        -b "admin_session=$cookie" -d "$2" "$HOST$1"
}

cmd_raw() {
    [ $# -ge 1 ] || die "usage: gctl raw <path>"
    curl -sS "$HOST$1"
}

[ $# -ge 1 ] || die "usage: gctl {session|get|post|put|raw} ..."
sub="$1"; shift
case "$sub" in
    session) cmd_session "$@" ;;
    get)     cmd_get     "$@" ;;
    post)    cmd_post    "$@" ;;
    put)     cmd_put     "$@" ;;
    raw)     cmd_raw     "$@" ;;
    *)       die "unknown subcommand: $sub" ;;
esac
