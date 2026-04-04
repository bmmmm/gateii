#!/bin/bash
# gateii admin — key management and usage stats
# Requires: docker compose up -d (gateii-redis must be running)
set -euo pipefail

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
    [[ "$1" =~ ^sk-proxy-[a-f0-9]{32}$|^sk-[a-zA-Z0-9_-]{20,200}$ ]] || {
        echo -e "${RED}Invalid key format — expected sk-proxy-<hex32> or sk-<20-200 chars>${NC}" >&2; exit 1
    }
}

case "$SUBCMD" in

  status)
    echo ""
    echo -e "${BOLD}gateii — status${NC}"
    echo ""
    KEYS_COUNT=$($REDIS HLEN keys 2>/dev/null || echo 0)
    BLOCKED=$($REDIS --scan --pattern 'blocked:*' 2>/dev/null | wc -l | tr -d ' ')
    echo -e "  Proxy keys:      ${CYN}${KEYS_COUNT}${NC}"
    echo -e "  Blocked users:   ${RED}${BLOCKED}${NC}"
    echo ""
    ;;

  users)
    echo ""
    echo -e "${BOLD}Token usage per user${NC}"
    echo ""
    for KEY in $($REDIS --scan --pattern 'usage:*'); do
        # Skip daily usage keys (usage_day:*)
        [[ "$KEY" == usage_day:* ]] && continue
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

  block)
    USER="${1:?Usage: admin.sh block <user> [seconds]}"
    validate_user "$USER"
    TTL="${2:-86400}"
    [[ "$TTL" =~ ^[0-9]+$ ]] || { echo -e "${RED}Invalid TTL — must be a positive integer (seconds)${NC}" >&2; exit 1; }
    $REDIS SET "blocked:${USER}" "manual" EX "$TTL"
    echo -e "${GRN}Blocked ${BOLD}$USER${NC} for ${TTL}s"
    ;;

  unblock)
    USER="${1:?Usage: admin.sh unblock <user>}"
    validate_user "$USER"
    RESULT=$($REDIS DEL "blocked:${USER}")
    if [ "$RESULT" = "1" ] || [ "$RESULT" = "(integer) 1" ]; then
      echo -e "${GRN}Unblocked ${BOLD}$USER${NC}"
    else
      echo -e "${YEL}${BOLD}$USER${NC} was not blocked"
    fi
    ;;

  limit)
    USER="${1:?Usage: admin.sh limit <user> <field> <value>}"
    FIELD="${2:?Usage: admin.sh limit <user> <field> <value>}"
    VALUE="${3:?Usage: admin.sh limit <user> <field> <value>}"
    validate_user "$USER"
    # Whitelist allowed fields
    case "$FIELD" in
      tokens_per_day|requests_per_day|tokens_per_month) ;;
      *) echo -e "${RED}Invalid field '$FIELD' — allowed: tokens_per_day, requests_per_day, tokens_per_month${NC}" >&2; exit 1 ;;
    esac
    [[ "$VALUE" =~ ^[0-9]+$ ]] || { echo -e "${RED}Invalid value — must be a positive integer${NC}" >&2; exit 1; }
    $REDIS HSET "limits:${USER}" "$FIELD" "$VALUE"
    echo -e "${GRN}Set ${BOLD}$USER${NC} ${FIELD}=${VALUE}"
    ;;

  limits)
    USER="${1:?Usage: admin.sh limits <user>}"
    validate_user "$USER"
    echo ""
    echo -e "${BOLD}Limits for $USER${NC}"
    echo ""
    DATA=$($REDIS HGETALL "limits:${USER}" 2>/dev/null)
    if [ -z "$DATA" ] || [ "$DATA" = "" ]; then
      echo -e "  ${DIM}No limits configured${NC}"
    else
      echo "$DATA" | paste - - | while read -r field value; do
        echo -e "  ${CYN}$field${NC}: $value"
      done
    fi
    BLOCKED=$($REDIS GET "blocked:${USER}" 2>/dev/null)
    if [ -n "$BLOCKED" ] && [ "$BLOCKED" != "(nil)" ]; then
      TTL=$($REDIS TTL "blocked:${USER}" 2>/dev/null)
      echo -e "  ${RED}BLOCKED${NC}: $BLOCKED (TTL: ${TTL}s)"
    fi
    # Show today's usage
    TODAY=$(date -u +%Y-%m-%d)
    DAY_KEY="usage_day:${USER}:${TODAY}"
    DAY_IN=$($REDIS HGET "$DAY_KEY" input 2>/dev/null || echo 0)
    DAY_OUT=$($REDIS HGET "$DAY_KEY" output 2>/dev/null || echo 0)
    DAY_REQS=$($REDIS HGET "$DAY_KEY" requests 2>/dev/null || echo 0)
    [ "$DAY_IN" = "(nil)" ] && DAY_IN=0
    [ "$DAY_OUT" = "(nil)" ] && DAY_OUT=0
    [ "$DAY_REQS" = "(nil)" ] && DAY_REQS=0
    echo ""
    echo -e "  ${DIM}Today ($TODAY):${NC} ${DAY_REQS} reqs, ${DAY_IN} in + ${DAY_OUT} out tokens"
    echo ""
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
    for KEY in $(docker exec gateii-redis redis-cli --scan --pattern "usage_day:${USER}:*"); do
      $REDIS DEL "$KEY"
    done
    echo -e "${GRN}Reset ${BOLD}$USER${NC} — $COUNT usage key(s) deleted"
    ;;

  help|--help|-h|"")
    echo ""
    echo -e "${BOLD}gateii admin${NC}"
    echo ""
    echo "  status                          Key count, blocked users"
    echo "  users                           Token usage per user"
    echo "  keys                            All proxy keys (masked)"
    echo "  add <user> [key]                Add proxy key (random if omitted)"
    echo "  revoke <key>                    Revoke a key"
    echo "  rotate <user>                   New key, revoke all old ones"
    echo "  reset <user>                    Reset usage counters"
    echo ""
    echo "  block <user> [seconds]          Block user (default 86400 = 1 day)"
    echo "  unblock <user>                  Unblock user"
    echo "  limit <user> <field> <value>    Set limit (tokens_per_day, requests_per_day, tokens_per_month)"
    echo "  limits <user>                   Show limits + today's usage"
    echo ""
    ;;

  *)
    echo -e "${RED}Unknown command: $SUBCMD — run 'admin.sh help'${NC}" >&2; exit 1
    ;;
esac
