#!/usr/bin/env bash
# proxy-hook.sh — install/remove the gateii proxy-routing reminder as a
# Claude Code UserPromptSubmit hook.
#
# The reminder (scripts/proxy-hint.sh) warns up to 3x per Claude Code session
# when ANTHROPIC_BASE_URL is not pointed at this gateii instance. It is only
# useful once you actively route Claude Code through gateii, so it is NOT
# installed globally — you opt in here as part of setting gateii up.
#
# Usage:
#   scripts/proxy-hook.sh install     # register the hook in ~/.claude/settings.json
#   scripts/proxy-hook.sh uninstall   # remove it again
#   scripts/proxy-hook.sh status      # show whether it is registered
#
# The hook points at this checkout's absolute proxy-hint.sh path, so moving or
# deleting the repo means you should re-run install / uninstall accordingly.
#
# Override the target file for testing:  CLAUDE_SETTINGS=/path/to/settings.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HINT="$SCRIPT_DIR/proxy-hint.sh"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; DIM=$'\033[2m'; NC=$'\033[0m'

die() { echo "${RED}✗${NC} $*" >&2; exit 1; }

# help must work even if settings.json is missing/broken — handle it first.
case "${1:-status}" in
    -h|--help|help)
        sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac

command -v jq >/dev/null 2>&1 || die "jq is required but not on PATH"
[ -x "$HINT" ] || die "proxy-hint.sh not found or not executable at $HINT"
[ -f "$SETTINGS" ] || die "Claude settings not found at $SETTINGS"

# jq must be able to parse the file — a malformed settings.json (Claude Code's
# loader is more tolerant than jq) would otherwise be silently rewritten.
jq empty "$SETTINGS" 2>/dev/null \
    || die "$SETTINGS is not valid JSON (jq cannot parse it). Fix it first, then retry."

# True if a proxy-hint command is currently registered under UserPromptSubmit.
is_installed() {
    jq -e '
        [ .hooks.UserPromptSubmit[]?.hooks[]?.command // "" ]
        | any(test("proxy-hint"))
    ' "$SETTINGS" >/dev/null 2>&1
}

# Atomically rewrite $SETTINGS with the jq program in $1 (extra args follow).
rewrite() {
    local prog="$1"; shift
    local tmp; tmp="$(mktemp "${SETTINGS}.XXXXXX")"
    if jq "$@" "$prog" "$SETTINGS" >"$tmp"; then
        mv "$tmp" "$SETTINGS"
    else
        rm -f "$tmp"
        die "jq rewrite failed — $SETTINGS left unchanged"
    fi
}

case "${1:-status}" in
    install)
        # Idempotent: drop any existing proxy-hint entries, then append a fresh
        # one pinned to this checkout's absolute path.
        rewrite '
            .hooks //= {}
            | .hooks.UserPromptSubmit = (
                (.hooks.UserPromptSubmit // [])
                | map(select((.hooks // []) | any((.command // "") | test("proxy-hint")) | not))
              )
            | .hooks.UserPromptSubmit += [
                { matcher: "", hooks: [ { type: "command", command: $cmd } ] }
              ]
        ' --arg cmd "$HINT"
        echo "${GRN}✓${NC} proxy-hint hook installed → ${DIM}$HINT${NC}"
        echo "${DIM}  Fires in every Claude Code session when ANTHROPIC_BASE_URL is not this gateii.${NC}"
        echo "${YEL}!${NC} If you manage ${SETTINGS/#$HOME/\~} via dotfiles, mirror this entry there too,"
        echo "${DIM}  otherwise the next dotfiles deploy removes it again.${NC}"
        ;;
    uninstall)
        # Remove proxy-hint entries; drop the UserPromptSubmit key if it ends up empty.
        rewrite '
            (.hooks.UserPromptSubmit // []) as $u
            | .hooks.UserPromptSubmit = (
                $u | map(select((.hooks // []) | any((.command // "") | test("proxy-hint")) | not))
              )
            | if (.hooks.UserPromptSubmit | length) == 0
              then del(.hooks.UserPromptSubmit) else . end
        '
        echo "${GRN}✓${NC} proxy-hint hook removed from ${DIM}$SETTINGS${NC}"
        ;;
    status)
        if is_installed; then
            echo "${GRN}✓${NC} proxy-hint hook is installed in $SETTINGS"
        else
            echo "${DIM}○ proxy-hint hook is not installed. Run: gateii hook install${NC}"
        fi
        ;;
    *)
        die "unknown action: ${1:-} (use install | uninstall | status)"
        ;;
esac
