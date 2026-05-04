#!/bin/sh
# env-check — sanity-check the project's .env without printing secret values.
# Outputs ✓ / ⚠ / ✗ / ⊘ per variable so you can see at a glance what's set,
# what's missing, and what's set-but-suspicious. Never echoes values.
#
# Usage:
#   bash scripts/env-check.sh           # short report
#   bash scripts/env-check.sh --verbose # also lists optional vars + their state
#
# DO NOT debug this script with `sh -x` — that prints variable expansions
# including secret values. To inspect logic, use a dummy ENV_FILE pointing to
# .env.example: `ENV_FILE=.env.example sh -x scripts/env-check.sh`.

set -eu

# Refuse to run under shell tracing (-x) — would leak ADMIN_TOKEN, OMLX_API_KEY
# etc. via bash trace output. The set -o option `xtrace` is what -x toggles.
case "$-" in
    *x*) echo "env-check: refusing to run under 'sh -x' / 'set -x' (would leak secrets via trace)" >&2; exit 2 ;;
esac
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

# ANSI (skip if NO_COLOR set or not a tty)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    G="\033[0;32m"; Y="\033[0;33m"; R="\033[0;31m"; D="\033[2m"; B="\033[1m"; N="\033[0m"
else
    G=""; Y=""; R=""; D=""; B=""; N=""
fi

if [ ! -f "$ENV_FILE" ]; then
    printf "%b✗ %s does not exist%b\n" "$R" "$ENV_FILE" "$N"
    printf "  copy %b.env.example%b to %b.env%b and fill in the must-haves\n" "$D" "$N" "$D" "$N"
    exit 1
fi

# Internal helpers — all read .env via grep without exposing values.
# `is_set` = uncommented line `VAR=…` exists and value is non-empty.
is_set() {
    grep -E "^[[:space:]]*$1=" "$ENV_FILE" 2>/dev/null \
        | grep -qE "^[[:space:]]*$1=.+$"
}
# `value_length` for format checks (length only, never the value itself)
value_length() {
    grep -E "^[[:space:]]*$1=" "$ENV_FILE" 2>/dev/null \
        | head -1 | sed -E "s/^[[:space:]]*$1=//" | tr -d '\r' | wc -c | tr -d ' '
}
# `value_matches` checks regex against value WITHOUT printing the value.
# Returns 0 if match, 1 if no match, 2 if not set.
value_matches() {
    var="$1"; pattern="$2"
    line=$(grep -E "^[[:space:]]*$var=" "$ENV_FILE" 2>/dev/null | head -1) || return 2
    [ -n "$line" ] || return 2
    val=$(echo "$line" | sed -E "s/^[[:space:]]*$var=//" | tr -d '\r')
    [ -n "$val" ] || return 2
    echo "$val" | grep -qE "$pattern"
}

ok()    { printf "  %b✓%b %-28s %s\n" "$G" "$N" "$1" "${2:-}"; }
warn()  { printf "  %b⚠%b %-28s %b%s%b\n" "$Y" "$N" "$1" "$D" "${2:-}" "$N"; }
miss()  { printf "  %b✗%b %-28s %b%s%b\n" "$R" "$N" "$1" "$D" "${2:-missing}" "$N"; }
skip()  { printf "  %b⊘%b %-28s %b%s%b\n" "$D" "$N" "$1" "$D" "${2:-not needed}" "$N"; }

PROXY_MODE_ACTUAL=""
if is_set PROXY_MODE; then
    line=$(grep -E "^[[:space:]]*PROXY_MODE=" "$ENV_FILE" | head -1)
    PROXY_MODE_ACTUAL=$(echo "$line" | sed -E "s/^[[:space:]]*PROXY_MODE=//" | tr -d '\r')
fi

# ─── Required ──────────────────────────────────────────────────────────────
printf "%bRequired%b\n" "$B" "$N"

case "$PROXY_MODE_ACTUAL" in
    passthrough) ok PROXY_MODE "passthrough — own credentials forwarded" ;;
    apikey)      ok PROXY_MODE "apikey — see data/keys.json" ;;
    "")          miss PROXY_MODE "must be 'passthrough' or 'apikey'" ;;
    *)           warn PROXY_MODE "unknown value (expected passthrough or apikey)" ;;
esac

if is_set ADMIN_TOKEN; then
    len=$(value_length ADMIN_TOKEN)
    # 64 hex chars = `openssl rand -hex 32` output (+1 for \n captured by wc)
    if [ "$len" -lt 32 ]; then
        warn ADMIN_TOKEN "set but only $((len-1)) chars (recommend 64-char hex from \`openssl rand -hex 32\`)"
    elif value_matches ADMIN_TOKEN '^[a-f0-9]{32,}$'; then
        ok ADMIN_TOKEN "set, hex format ($((len-1)) chars)"
    else
        ok ADMIN_TOKEN "set ($((len-1)) chars, non-hex format)"
    fi
else
    if [ "$PROXY_MODE_ACTUAL" = "passthrough" ]; then
        warn ADMIN_TOKEN "unset — /console reachable but cannot mutate state"
    else
        miss ADMIN_TOKEN "required for apikey mode (admin.sh, console, bootstrap)"
    fi
fi

# ─── Workflow-relevant for this user ───────────────────────────────────────
echo
printf "%bWorkflow%b\n" "$B" "$N"

if is_set PASSTHROUGH_USER; then
    ok PASSTHROUGH_USER "set — Grafana shows this name"
elif [ "$PROXY_MODE_ACTUAL" = "passthrough" ]; then
    warn PASSTHROUGH_USER "unset — Grafana derives name from key suffix"
else
    skip PASSTHROUGH_USER "not used in apikey mode"
fi

if value_matches CONSOLE_ENABLED '^1$'; then
    ok CONSOLE_ENABLED "console at /console enabled"
elif is_set CONSOLE_ENABLED; then
    warn CONSOLE_ENABLED "set to non-1 — console is disabled"
else
    warn CONSOLE_ENABLED "unset — /console returns 404"
fi

if value_matches GIT_TRACKING_ENABLED '^1$'; then
    ok GIT_TRACKING_ENABLED "plugin enabled"
    # If git-tracking.json exists with a default_author, the JSON wins —
    # warn the user if the env value disagrees so they don't waste time
    # wondering why their .env-set author isn't being used.
    JSON_FILE="$PROJECT_DIR/data/git-tracking.json"
    JSON_DEFAULT_AUTHOR=""
    if [ -f "$JSON_FILE" ] && command -v jq >/dev/null 2>&1; then
        JSON_DEFAULT_AUTHOR=$(jq -r '.default_author // ""' "$JSON_FILE" 2>/dev/null)
    fi
    if is_set GIT_AUTHOR; then
        ENV_AUTHOR=$(grep -E '^[[:space:]]*GIT_AUTHOR=' "$ENV_FILE" | head -1 | sed -E 's/^[[:space:]]*GIT_AUTHOR=//' | tr -d '\r')
        if [ -n "$JSON_DEFAULT_AUTHOR" ] && [ "$JSON_DEFAULT_AUTHOR" != "$ENV_AUTHOR" ]; then
            warn GIT_AUTHOR "set in .env but git-tracking.json has a different default_author — JSON wins"
        else
            ok GIT_AUTHOR "set (fallback for repos without git-tracking.json override)"
        fi
    else
        if [ -n "$JSON_DEFAULT_AUTHOR" ]; then
            ok GIT_AUTHOR "unset in .env (git-tracking.json provides default_author)"
        else
            warn GIT_AUTHOR "unset — counts ALL authors' commits"
        fi
    fi
else
    skip GIT_TRACKING_ENABLED "git-tracking plugin disabled"
fi

# ─── Routing helpers ───────────────────────────────────────────────────────
echo
printf "%bRouting (gateii up)%b\n" "$B" "$N"

if value_matches GATEII_PREUP_HOOK '^scripts/hooks/colima\.sh$'; then
    ok GATEII_PREUP_HOOK "Colima auto-start hook"
elif is_set GATEII_PREUP_HOOK; then
    ok GATEII_PREUP_HOOK "custom hook"
else
    if [ "$(uname)" = "Darwin" ]; then
        warn GATEII_PREUP_HOOK "unset — set to scripts/hooks/colima.sh on macOS+Colima"
    else
        skip GATEII_PREUP_HOOK "Linux — no hook needed"
    fi
fi

if value_matches GATEII_DEFAULT_ROUTE '^(local-proxy|remote-proxy|direct)$'; then
    ok GATEII_DEFAULT_ROUTE "set"
else
    [ "$VERBOSE" = "1" ] && skip GATEII_DEFAULT_ROUTE "unset — gateii up falls back to local-proxy hint"
fi

# ─── OMLX (only show if explicitly configured or if you want full picture) ─
echo
printf "%bOMLX (optional)%b\n" "$B" "$N"

if is_set OMLX_URL; then
    if value_matches OMLX_URL '^https?://'; then
        ok OMLX_URL "set"
    else
        warn OMLX_URL "set but doesn't look like a URL"
    fi
    if is_set OMLX_API_KEY; then
        ok OMLX_API_KEY "set"
    elif [ "$VERBOSE" = "1" ]; then
        skip OMLX_API_KEY "no auth — typical for local omlx"
    fi
else
    skip OMLX_URL "not configured — omlx provider falls back to host.docker.internal:8000"
fi

# ─── Sanity / hardening (verbose only) ─────────────────────────────────────
if [ "$VERBOSE" = "1" ]; then
    echo
    printf "%bOptional / hardening%b\n" "$B" "$N"
    for v in HISTORY_RETENTION GATEII_AUTO_SWITCH REMOTE_URL OPENROUTER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY \
             RATE_LIMIT_RPS RATE_LIMIT_BURST CB_FAILURE_THRESHOLD CB_COOLDOWN_SECONDS \
             AUTH_CACHE_NEG_TTL AUTH_CACHE_POS_TTL HEALTH_CHECK_READ_MS COUNTER_RETENTION_DAYS; do
        if is_set "$v"; then
            ok "$v" "set"
        else
            skip "$v" "default"
        fi
    done
fi

# ─── Stale entries (vars no longer referenced anywhere) ────────────────────
echo
printf "%bStale entries%b\n" "$B" "$N"
ANY_STALE=0
for v in HEARTBEAT_ENABLED HEARTBEAT_INTERVAL_SECONDS HEARTBEAT_UPSTREAM_KEY HEARTBEAT_MODEL; do
    if is_set "$v"; then
        warn "$v" "from removed heartbeat feature — safe to delete from .env"
        ANY_STALE=1
    fi
done
[ "$ANY_STALE" = "0" ] && printf "  %b⊘%b none — clean\n" "$D" "$N"

echo
printf "%bDone.%b Run with %b--verbose%b to see optional vars too.\n" "$B" "$N" "$D" "$N"
