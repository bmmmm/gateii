#!/bin/bash
# gateii admin — key management, blocking, and usage stats
# Uses keys.json (via jq) for API key management and HTTP admin API for blocking
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Source .env for port/host configuration
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a; source "$PROJECT_DIR/.env"; set +a
fi

PROXY_HOST="${PROXY_HOST:-localhost}"
PROXY_PORT="${PROXY_PORT:-8888}"
GRAFANA_PORT="${GRAFANA_PORT:-3001}"

PROXY="http://${PROXY_HOST}:${PROXY_PORT}"
ADMIN="${PROXY}/internal/admin"
KEYS_FILE="${PROJECT_DIR}/data/keys.json"

# Ensure keys.json exists
if [ ! -f "$KEYS_FILE" ]; then
    mkdir -p "$(dirname "$KEYS_FILE")"
    echo '{}' > "$KEYS_FILE"
fi

# Check jq is available
command -v jq >/dev/null 2>&1 || {
    echo -e "\033[0;31mjq is required but not installed — brew install jq / apt install jq\033[0m" >&2
    exit 1
}

SUBCMD="${1:-help}"
shift 2>/dev/null || true

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

validate_user() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]{1,64}$ ]] || {
        echo -e "${RED}Invalid username — only letters, digits, _ and - allowed${NC}" >&2; exit 1
    }
}
validate_key() {
    [[ "$1" =~ ^sk-proxy-[a-f0-9]{32}$|^sk-[a-zA-Z0-9_-]{20,200}$ ]] || {
        echo -e "${RED}Invalid key format — expected sk-proxy-<hex32> or sk-<20-200 chars>${NC}" >&2; exit 1
    }
}

# Atomic write to keys.json via temp file
write_keys() {
    local tmp="${KEYS_FILE}.tmp"
    jq "$@" "$KEYS_FILE" > "$tmp" && mv "$tmp" "$KEYS_FILE"
}

reload_proxy() {
    docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T openresty nginx -s reload 2>/dev/null || true
}

case "$SUBCMD" in

  status)
    echo ""
    echo -e "${BOLD}gateii — status${NC}"
    echo ""
    KEYS_COUNT=$(jq 'length' "$KEYS_FILE" 2>/dev/null || echo 0)
    echo -e "  Proxy keys:      ${CYN}${KEYS_COUNT}${NC}"
    BLOCKED=$(curl -sf --max-time 5 "$ADMIN/status" 2>/dev/null || echo '{"blocked":[]}')
    BLOCKED_COUNT=$(echo "$BLOCKED" | jq '.blocked | length' 2>/dev/null || echo 0)
    echo -e "  Blocked users:   ${RED}${BLOCKED_COUNT}${NC}"
    echo ""
    ;;

  users)
    echo ""
    echo -e "${BOLD}Usage stats${NC}"
    echo ""
    echo -e "  ${DIM}Check Grafana at http://${PROXY_HOST}:${GRAFANA_PORT} for detailed stats${NC}"
    echo -e "  ${DIM}Or curl ${PROXY}/metrics for raw counters${NC}"
    echo ""
    ;;

  keys)
    echo ""
    echo -e "${BOLD}Proxy keys${NC}"
    COUNT=$(jq 'length' "$KEYS_FILE" 2>/dev/null || echo 0)
    if [ "$COUNT" -eq 0 ]; then
      echo -e "  ${DIM}No keys configured${NC}"
    else
      jq -r 'to_entries[] | "\(.key[:12])...\(.key[-6:])\t\(.value)"' "$KEYS_FILE" 2>/dev/null | \
        while IFS=$'\t' read -r masked user; do
          echo -e "  ${CYN}${masked}${NC}  ->  ${BOLD}${user}${NC}"
        done
    fi
    echo ""
    ;;

  add)
    USER="${1:?Usage: admin.sh add <user> [key]}"
    KEY="${2:-sk-proxy-$(openssl rand -hex 16)}"
    validate_user "$USER"
    validate_key "$KEY"
    write_keys --arg key "$KEY" --arg user "$USER" '. + {($key): $user}'
    reload_proxy
    echo -e "${GRN}Added key for ${BOLD}$USER${NC}"
    echo -e "  Key: ${CYN}$KEY${NC}"
    echo -e "  ${DIM}Set ANTHROPIC_API_KEY=$KEY in your Claude settings${NC}"
    ;;

  revoke)
    KEY="${1:?Usage: admin.sh revoke <key>}"
    validate_key "$KEY"
    USER=$(jq -r --arg key "$KEY" '.[$key] // empty' "$KEYS_FILE" 2>/dev/null)
    if [ -z "$USER" ]; then
      echo -e "${RED}Key not found${NC}" >&2; exit 1
    fi
    write_keys --arg key "$KEY" 'del(.[$key])'
    reload_proxy
    echo -e "${GRN}Revoked key for ${BOLD}$USER${NC}"
    echo -e "  ${DIM}Auth cache expires in up to 5 minutes${NC}"
    ;;

  rotate)
    USER="${1:?Usage: admin.sh rotate <user>}"
    validate_user "$USER"
    NEW_KEY="sk-proxy-$(openssl rand -hex 16)"
    validate_key "$NEW_KEY"
    # Show old keys being revoked
    jq -r --arg user "$USER" 'to_entries[] | select(.value == $user) | .key' "$KEYS_FILE" | \
      while read -r old_key; do
        echo -e "  ${DIM}Revoked: ${old_key:0:12}...${old_key: -6}${NC}"
      done
    # Remove all old keys for user, add new one
    write_keys --arg user "$USER" --arg new_key "$NEW_KEY" \
      '[to_entries[] | select(.value != $user)] | from_entries + {($new_key): $user}'
    reload_proxy
    echo -e "${GRN}New key for ${BOLD}$USER${NC}: ${CYN}$NEW_KEY${NC}"
    ;;

  block)
    USER="${1:?Usage: admin.sh block <user> [seconds]}"
    validate_user "$USER"
    TTL="${2:-86400}"
    [[ "$TTL" =~ ^[0-9]+$ ]] || { echo -e "${RED}Invalid TTL — must be a positive integer (seconds)${NC}" >&2; exit 1; }
    RESULT=$(curl -sf --max-time 5 -X POST "$ADMIN/block?user=$USER&ttl=$TTL" 2>/dev/null || echo "")
    if echo "$RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
      echo -e "${GRN}Blocked ${BOLD}$USER${NC} for ${TTL}s"
    else
      echo -e "${RED}Failed to block user — is the proxy running?${NC}" >&2; exit 1
    fi
    ;;

  unblock)
    USER="${1:?Usage: admin.sh unblock <user>}"
    validate_user "$USER"
    RESULT=$(curl -sf --max-time 5 -X POST "$ADMIN/unblock?user=$USER" 2>/dev/null || echo "")
    if echo "$RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
      echo -e "${GRN}Unblocked ${BOLD}$USER${NC}"
    else
      echo -e "${RED}Failed to unblock user — is the proxy running?${NC}" >&2; exit 1
    fi
    ;;

  limit)
    USER="${1:?Usage: admin.sh limit <user> <field> <value>}"
    FIELD="${2:?Usage: admin.sh limit <user> <field> <value>}"
    VALUE="${3:?Usage: admin.sh limit <user> <field> <value>}"
    validate_user "$USER"
    case "$FIELD" in
      tokens_per_day|requests_per_day) ;;
      *) echo -e "${RED}Invalid field '$FIELD' — allowed: tokens_per_day, requests_per_day${NC}" >&2; exit 1 ;;
    esac
    [[ "$VALUE" =~ ^[0-9]+$ ]] || { echo -e "${RED}Invalid value — must be a positive integer${NC}" >&2; exit 1; }
    RESULT=$(curl -sf --max-time 5 -X POST "$ADMIN/limit?user=$USER" \
      -d "$(jq -nc --arg f "$FIELD" --argjson v "$VALUE" '{($f): $v}')" 2>/dev/null || echo "")
    if echo "$RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
      echo -e "${GRN}Set ${BOLD}$USER${NC} ${FIELD}=${VALUE}"
    else
      echo -e "${RED}Failed to set limit — is the proxy running?${NC}" >&2; exit 1
    fi
    ;;

  limits)
    USER="${1:?Usage: admin.sh limits <user>}"
    validate_user "$USER"
    echo ""
    echo -e "${BOLD}Usage for $USER${NC}"
    echo ""
    RESULT=$(curl -sf --max-time 5 "$ADMIN/usage?user=$USER" 2>/dev/null || echo "")
    if [ -n "$RESULT" ]; then
      echo "$RESULT" | jq -r '"  Today (\(.today)): \(.daily_requests) reqs, \(.daily_input) in + \(.daily_output) out tokens"' \
        2>/dev/null || echo -e "  ${DIM}Could not parse response${NC}"
    else
      echo -e "  ${RED}Could not reach admin API — is the proxy running?${NC}"
    fi
    echo ""
    ;;

  switch)
    TARGET="${1:?Usage: admin.sh switch <local|direct>}"
    CLAUDE_SETTINGS="$HOME/.claude/settings.json"
    if [ ! -f "$CLAUDE_SETTINGS" ]; then
      echo -e "${RED}Claude settings not found at $CLAUDE_SETTINGS${NC}" >&2; exit 1
    fi

    case "$TARGET" in
      local)
        # Safety: check proxy is reachable before switching
        if ! curl -sf --max-time 2 "$PROXY/health" >/dev/null 2>&1; then
          echo -e "${RED}Proxy not reachable at $PROXY — start it first:${NC}" >&2
          echo -e "  ${DIM}cd $PROJECT_DIR && docker compose up -d${NC}" >&2
          exit 1
        fi
        local tmp="${CLAUDE_SETTINGS}.tmp"
        jq --arg url "$PROXY" '.env //= {} | .env.ANTHROPIC_BASE_URL = $url' \
          "$CLAUDE_SETTINGS" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
        echo -e "${GRN}Switched to local proxy${NC} ($PROXY)"
        echo -e "  ${DIM}Restart Claude Code to apply${NC}"
        ;;
      direct)
        local tmp="${CLAUDE_SETTINGS}.tmp"
        jq 'if .env then .env |= del(.ANTHROPIC_BASE_URL) else . end' \
          "$CLAUDE_SETTINGS" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
        echo -e "${GRN}Switched to direct Anthropic connection${NC}"
        echo -e "  ${DIM}Restart Claude Code to apply. Safe to stop the proxy now.${NC}"
        ;;
      *)
        echo -e "${RED}Unknown target '$TARGET' — use 'local' or 'direct'${NC}" >&2; exit 1
        ;;
    esac
    ;;

  help|--help|-h|"")
    echo ""
    echo -e "${BOLD}gateii admin${NC}"
    echo ""
    echo "  ${BOLD}Proxy routing${NC}"
    echo "  switch local                    Route Claude Code through proxy (checks health first)"
    echo "  switch direct                   Route Claude Code directly to Anthropic"
    echo ""
    echo "  ${BOLD}Key management${NC} (apikey mode)"
    echo "  keys                            All proxy keys (masked)"
    echo "  add <user> [key]                Add proxy key (random if omitted)"
    echo "  revoke <key>                    Revoke a key"
    echo "  rotate <user>                   New key, revoke all old ones"
    echo ""
    echo "  ${BOLD}Limits & blocking${NC}"
    echo "  block <user> [seconds]          Block user (default 86400 = 1 day)"
    echo "  unblock <user>                  Unblock user"
    echo "  limit <user> <field> <value>    Set limit (tokens_per_day, requests_per_day)"
    echo "  limits <user>                   Show today's usage"
    echo ""
    echo "  ${BOLD}Info${NC}"
    echo "  status                          Key count, blocked users"
    echo "  users                           Usage stats (→ Grafana)"
    echo ""
    ;;

  *)
    echo -e "${RED}Unknown command: $SUBCMD — run 'admin.sh help'${NC}" >&2; exit 1
    ;;
esac
