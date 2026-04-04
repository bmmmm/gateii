#!/bin/bash
# gateii admin — key management and usage stats
# Requires: docker compose up -d (gateii-redis must be running)
set -e

REDIS="docker exec gateii-redis redis-cli"
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
    [[ "$1" =~ ^sk-proxy-[a-f0-9]{32}$|^sk-[a-zA-Z0-9_-]{20,}$ ]] || {
        echo -e "${RED}Invalid key format${NC}" >&2; exit 1
    }
}

case "$SUBCMD" in

  status)
    echo ""
    echo -e "${BOLD}gateii — status${NC}"
    echo ""
    KEYS_COUNT=$($REDIS HLEN keys 2>/dev/null || echo 0)
    HITS=$($REDIS GET cache:hits 2>/dev/null || echo 0)
    MISSES=$($REDIS GET cache:misses 2>/dev/null || echo 0)
    echo -e "  Proxy keys:   ${CYN}${KEYS_COUNT}${NC}"
    echo -e "  Cache hits:   ${GRN}${HITS}${NC}"
    echo -e "  Cache misses: ${HITS:+}${MISSES}${NC}"
    echo ""
    ;;

  users)
    echo ""
    echo -e "${BOLD}Token usage per user${NC}"
    echo ""
    for KEY in $($REDIS --scan --pattern 'usage:*'); do
        PARTS=$(echo "$KEY" | awk -F: '{print $2, $3, $4}')
        USER=$(echo "$PARTS" | awk '{print $1}')
        MODEL=$(echo "$PARTS" | awk '{print $3}')
        IN=$($REDIS HGET "$KEY" input 2>/dev/null || echo 0)
        OUT=$($REDIS HGET "$KEY" output 2>/dev/null || echo 0)
        REQS=$($REDIS HGET "$KEY" requests 2>/dev/null || echo 0)
        echo -e "  ${BOLD}$USER${NC} / ${DIM}$MODEL${NC}"
        echo -e "    requests: $REQS  input: $IN  output: $OUT"
    done
    echo ""
    ;;

  keys)
    echo ""
    echo -e "${BOLD}Proxy keys${NC}"
    $REDIS HGETALL keys | paste - - | while read -r key user; do
        MASKED="${key:0:12}...${key: -6}"
        echo -e "  ${CYN}$MASKED${NC}  →  ${BOLD}$user${NC}"
    done
    echo ""
    ;;

  add)
    USER="${1:?Usage: admin.sh add <user> [key]}"
    KEY="${2:-sk-proxy-$(openssl rand -hex 16)}"
    validate_user "$USER"
    validate_key "$KEY"
    $REDIS HSET keys "$KEY" "$USER"
    echo -e "${GRN}Added key for ${BOLD}$USER${NC}"
    echo -e "  Key: ${CYN}$KEY${NC}"
    echo -e "  ${DIM}Set ANTHROPIC_API_KEY=$KEY in your Claude settings${NC}"
    ;;

  revoke)
    KEY="${1:?Usage: admin.sh revoke <key>}"
    validate_key "$KEY"
    USER=$($REDIS HGET keys "$KEY")
    if [ -z "$USER" ] || [ "$USER" = "(nil)" ]; then
      echo -e "${RED}Key not found${NC}" >&2; exit 1
    fi
    $REDIS HDEL keys "$KEY"
    echo -e "${GRN}Revoked key for ${BOLD}$USER${NC}"
    echo -e "  ${DIM}Auth cache expires in up to 5 minutes${NC}"
    ;;

  rotate)
    USER="${1:?Usage: admin.sh rotate <user>}"
    validate_user "$USER"
    OLD_KEYS=$($REDIS HGETALL keys | paste - - | awk -v u="$USER" '$2==u {print $1}')
    NEW_KEY="sk-proxy-$(openssl rand -hex 16)"
    validate_key "$NEW_KEY"
    $REDIS HSET keys "$NEW_KEY" "$USER"
    echo -e "${GRN}New key for ${BOLD}$USER${NC}: ${CYN}$NEW_KEY${NC}"
    if [ -n "$OLD_KEYS" ]; then
      echo "$OLD_KEYS" | while read -r k; do
        [ -z "$k" ] && continue
        $REDIS HDEL keys "$k"
        echo -e "  ${DIM}Revoked: ${k:0:12}...${k: -6}${NC}"
      done
    fi
    ;;

  reset)
    USER="${1:?Usage: admin.sh reset <user>}"
    validate_user "$USER"
    COUNT=0
    for KEY in $(docker exec gateii-redis redis-cli --scan --pattern "usage:${USER}:*"); do
      $REDIS DEL "$KEY"; COUNT=$((COUNT+1))
    done
    for KEY in $(docker exec gateii-redis redis-cli --scan --pattern "stop:${USER}:*"); do
      $REDIS DEL "$KEY"
    done
    echo -e "${GRN}Reset ${BOLD}$USER${NC} — $COUNT usage key(s) deleted"
    ;;

  help|--help|-h|"")
    echo ""
    echo -e "${BOLD}gateii admin${NC}"
    echo ""
    echo "  status              Cache hits, key count"
    echo "  users               Token usage per user"
    echo "  keys                All proxy keys (masked)"
    echo "  add <user> [key]    Add proxy key (random if omitted)"
    echo "  revoke <key>        Revoke a key"
    echo "  rotate <user>       New key, revoke all old ones"
    echo "  reset <user>        Reset usage counters"
    echo ""
    ;;

  *)
    echo -e "${RED}Unknown command: $SUBCMD — run 'admin.sh help'${NC}" >&2; exit 1
    ;;
esac
