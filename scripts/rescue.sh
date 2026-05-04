#!/bin/bash
# rescue.sh — emergency recovery when the gateii proxy is broken
#
# What it does:
#   1. Removes ANTHROPIC_BASE_URL from ~/.claude/settings.json (direct Anthropic)
#   2. Sweeps project-local overrides: any <root>/*/.claude/settings.local.json
#      whose ANTHROPIC_BASE_URL points to localhost / 127.0.0.1 / REMOTE_URL
#      gets that key removed. Non-gateii overrides are left alone.
#   3. Restarts the gateii-proxy container
#
# Usage:
#   ./scripts/rescue.sh            — switch direct + sweep + restart proxy
#   ./scripts/rescue.sh --no-restart  — direct + sweep only (Docker broken too)
#   ./scripts/rescue.sh --no-sweep    — direct + restart only (skip project sweep)
#
# Project roots scanned (max depth 4):
#   $GATEII_PROJECT_ROOTS (space-separated) if set, else any of these that exist:
#     $HOME/offline_coding $HOME/coding $HOME/projects $HOME/dev $HOME/src
#
# After running: restart Claude Code, then test the fix, then:
#   ./scripts/admin.sh switch local-proxy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

NO_RESTART=""
NO_SWEEP=""
for arg in "$@"; do
    case "$arg" in
        --no-restart) NO_RESTART=1 ;;
        --no-sweep)   NO_SWEEP=1 ;;
        -h|--help)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "unknown arg: $arg (use -h for help)" >&2; exit 2 ;;
    esac
done

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

# ── Step 2: Sweep project-local overrides ─────────────────────────────────────
if [ -n "$NO_SWEEP" ]; then
    echo -e "  ${DIM}Skipping project sweep (--no-sweep)${NC}"
    echo ""
else
    # Determine roots
    if [ -n "${GATEII_PROJECT_ROOTS:-}" ]; then
        ROOTS="$GATEII_PROJECT_ROOTS"
    else
        ROOTS=""
        for cand in "$HOME/offline_coding" "$HOME/coding" "$HOME/projects" "$HOME/dev" "$HOME/src"; do
            [ -d "$cand" ] && ROOTS="$ROOTS $cand"
        done
    fi

    # Pull REMOTE_URL from .env (used to identify gateii-routed overrides)
    REMOTE_URL=""
    if [ -f "$PROJECT_DIR/.env" ]; then
        REMOTE_URL=$(awk -F= '/^REMOTE_URL=/{sub(/^[ \t]+/,"",$2); print $2; exit}' "$PROJECT_DIR/.env" 2>/dev/null)
    fi

    if [ -z "$ROOTS" ]; then
        echo -e "  ${DIM}No project roots found to sweep${NC}"
        echo -e "  ${DIM}  Override with GATEII_PROJECT_ROOTS=\"/path/one /path/two\"${NC}"
    else
        echo -e "  Sweeping project overrides under:${ROOTS}"
        SWEEP_FILES=""
        for root in $ROOTS; do
            FOUND=$(find "$root" -maxdepth 4 -type f -path '*/.claude/settings.local.json' 2>/dev/null)
            [ -n "$FOUND" ] && SWEEP_FILES="${SWEEP_FILES}${FOUND}
"
        done
        SWEEP_OUT=$(SWEEP_FILES="$SWEEP_FILES" REMOTE_URL="$REMOTE_URL" python3 <<'PYEOF'
import json, os, sys
remote = (os.environ.get("REMOTE_URL") or "").strip()
files  = (os.environ.get("SWEEP_FILES") or "").splitlines()
swept, scanned, skipped = [], 0, 0
for path in files:
    path = path.strip()
    if not path: continue
    scanned += 1
    try:
        with open(path) as fh: d = json.load(fh)
    except Exception:
        skipped += 1; continue
    env = d.get('env') or {}
    url = env.get('ANTHROPIC_BASE_URL', '')
    if not url:
        continue
    is_gateii = (
        'localhost:' in url or '127.0.0.1:' in url
        or (remote and url == remote)
    )
    if not is_gateii:
        continue
    env.pop('ANTHROPIC_BASE_URL', None)
    d['env'] = env
    tmp = path + '.rescue.tmp'
    with open(tmp, 'w') as fh:
        json.dump(d, fh, indent=2); fh.write('\n')
    os.replace(tmp, path)
    swept.append(path)
print(f"SCANNED {scanned}")
print(f"SKIPPED {skipped}")
for p in swept:
    print(f"SWEPT {p}")
PYEOF
        )
        SCANNED=$(printf '%s' "$SWEEP_OUT" | awk '/^SCANNED/{print $2}')
        SWEPT_COUNT=$(printf '%s\n' "$SWEEP_OUT" | grep -c '^SWEPT' || true)
        echo -e "  ${GRN}✓${NC} Scanned ${SCANNED:-0} project file(s); reset ${SWEPT_COUNT:-0} gateii-routed override(s)"
        printf '%s\n' "$SWEEP_OUT" | awk '/^SWEPT/{print "    " $2}' | sed "s|^    $HOME|    ~|"
    fi
    echo ""
fi

# ── Step 3: Restart proxy container ───────────────────────────────────────────
if [ -n "$NO_RESTART" ]; then
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
echo -e "  ${DIM}1. Restart Claude Code in any affected dir (picks up direct Anthropic)${NC}"
echo -e "  ${DIM}2. Fix the proxy issue, then reload: docker exec gateii-proxy openresty -s reload${NC}"
echo -e "  ${DIM}3. Switch back: gateii switch local-proxy${NC}"
echo ""
