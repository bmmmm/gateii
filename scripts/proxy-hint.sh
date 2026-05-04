#!/usr/bin/env bash
# proxy-hint.sh — UserPromptSubmit hook
# Warns up to 3x per Claude Code session when not routed through gateii.

PROXY_HOST="localhost:8888"
MAX_HINTS=3

# Already on proxy? Nothing to do.
[[ "${ANTHROPIC_BASE_URL:-}" == *"$PROXY_HOST"* ]] && exit 0

# Session key: walk up the process tree to find the claude CLI process.
# Using that PID keeps the counter stable across all hook invocations within
# one session, even though each invocation is a new subprocess.
_pid=$PPID
for _ in 1 2 3 4 5; do
    _cmd=$(ps -p "$_pid" -o comm= 2>/dev/null | tr -d ' ')
    case "$_cmd" in
        *claude*) break ;;
    esac
    _next=$(ps -p "$_pid" -o ppid= 2>/dev/null | tr -d ' ')
    [ -z "$_next" ] || [ "$_next" -le 1 ] && break
    _pid=$_next
done

HINT_FILE="${TMPDIR:-/tmp}/gateii-proxy-hint-${_pid}"
count=0
[ -f "$HINT_FILE" ] && count=$(cat "$HINT_FILE" 2>/dev/null) || true
[[ "$count" =~ ^[0-9]+$ ]] || count=0

[ "$count" -ge "$MAX_HINTS" ] && exit 0

printf '%d' $((count + 1)) > "$HINT_FILE"

printf '\033[33m[gateii]\033[0m Not routed through proxy. Run in your terminal: gateii switch local-proxy\n' >&2
