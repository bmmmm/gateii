#!/bin/bash
# gateii admin — key management, blocking, and usage stats
# Uses keys.json (via jq) for API key management and HTTP admin API for blocking
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Auto-detect Docker socket (handles Colima on macOS)
if [ -z "${DOCKER_HOST:-}" ]; then
    COLIMA_SOCK="$HOME/.colima/default/docker.sock"
    if [ -S "$COLIMA_SOCK" ]; then
        export DOCKER_HOST="unix://$COLIMA_SOCK"
    fi
fi

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

# Admin token (optional) — sent as X-Admin-Token header when set. Protects the
# admin API against lateral movement on the Docker network.
# Wrapped in a function because `"${arr[@]}"` on an empty array trips `set -u`
# on older bash (shipped with macOS).
admin_curl() {
    if [ -n "${ADMIN_TOKEN:-}" ]; then
        curl -H "X-Admin-Token: ${ADMIN_TOKEN}" "$@"
    else
        curl "$@"
    fi
}

# Ensure keys.json exists
if [ ! -f "$KEYS_FILE" ]; then
    mkdir -p "$(dirname "$KEYS_FILE")"
    echo '{}' > "$KEYS_FILE"
elif ! jq empty "$KEYS_FILE" 2>/dev/null; then
    echo -e "\033[0;31mWarning: $KEYS_FILE is corrupt JSON — backing up and resetting\033[0m" >&2
    cp "$KEYS_FILE" "${KEYS_FILE}.backup.$(date +%s)"
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
    if jq "$@" "$KEYS_FILE" > "$tmp"; then
        mv "$tmp" "$KEYS_FILE"
    else
        rm -f "$tmp"
        echo -e "${RED}Failed to update keys.json${NC}" >&2
        return 1
    fi
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
    BLOCKED=$(admin_curl -sf --max-time 5 "$ADMIN/status" 2>/dev/null || echo '{"blocked":[]}')
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
    [ "$TTL" -gt 31536000 ] && { echo "TTL too large — max 31536000 (1 year)" >&2; exit 1; }
    RESULT=$(admin_curl -sf --max-time 5 -X POST "$ADMIN/block?user=$USER&ttl=$TTL" 2>/dev/null || echo "")
    if echo "$RESULT" | jq -e '.ok == true' >/dev/null 2>&1; then
      echo -e "${GRN}Blocked ${BOLD}$USER${NC} for ${TTL}s"
    else
      echo -e "${RED}Failed to block user — is the proxy running?${NC}" >&2; exit 1
    fi
    ;;

  unblock)
    USER="${1:?Usage: admin.sh unblock <user>}"
    validate_user "$USER"
    RESULT=$(admin_curl -sf --max-time 5 -X POST "$ADMIN/unblock?user=$USER" 2>/dev/null || echo "")
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
    RESULT=$(admin_curl -sf --max-time 5 -X POST "$ADMIN/limit?user=$USER" \
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
    RESULT=$(admin_curl -sf --max-time 5 "$ADMIN/usage?user=$USER" 2>/dev/null || echo "")
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
        # Safety: check proxy is reachable with retries (10 attempts, 2s between each)
        attempts=0
        until curl -sf --max-time 2 "$PROXY/health" >/dev/null 2>&1; do
          attempts=$((attempts + 1))
          if [ $attempts -ge 10 ]; then
            echo -e "  ${RED}✗${NC} Proxy not reachable after 20s — start it first:" >&2
            echo -e "  ${DIM}  DOCKER_CONTEXT=colima docker compose up -d${NC}" >&2
            exit 1
          fi
          echo -e "  ${DIM}  Waiting for proxy... (${attempts}/10)${NC}"
          sleep 2
        done
        TMP="${CLAUDE_SETTINGS}.tmp"
        jq --arg url "$PROXY" '.env //= {} | .env.ANTHROPIC_BASE_URL = $url' \
          "$CLAUDE_SETTINGS" > "$TMP" && mv "$TMP" "$CLAUDE_SETTINGS"
        echo -e "${GRN}Switched to local proxy${NC} ($PROXY)"
        echo -e "  ${DIM}Restart Claude Code to apply${NC}"
        ;;
      direct)
        TMP="${CLAUDE_SETTINGS}.tmp"
        jq 'if .env then .env |= del(.ANTHROPIC_BASE_URL) else . end' \
          "$CLAUDE_SETTINGS" > "$TMP" && mv "$TMP" "$CLAUDE_SETTINGS"
        echo -e "${GRN}Switched to direct Anthropic connection${NC}"
        echo -e "  ${DIM}Restart Claude Code to apply. Safe to stop the proxy now.${NC}"
        ;;
      *)
        echo -e "${RED}Unknown target '$TARGET' — use 'local' or 'direct'${NC}" >&2; exit 1
        ;;
    esac
    ;;

  plugin)
    ACTION="${1:-list}"
    PLUGIN="${2:-}"
    shift 2 2>/dev/null || shift $# 2>/dev/null || true
    OVERRIDE="$PROJECT_DIR/docker-compose.override.yml"
    COMPOSE="docker compose --project-directory \"$PROJECT_DIR\" -f \"$PROJECT_DIR/docker-compose.yml\" --env-file \"$PROJECT_DIR/.env\""
    # Include override if it exists
    if [ -f "$OVERRIDE" ]; then
      COMPOSE="$COMPOSE -f \"$OVERRIDE\""
    fi

    # Available plugins (name → description)
    PLUGINS="console:Admin web console at /console (key management, limits, stats)
git-tracking:Track git activity (commits, lines) alongside token usage"

    case "$ACTION" in
      list|ls)
        echo ""
        echo -e "${BOLD}Available plugins${NC}"
        echo ""
        echo "$PLUGINS" | while IFS=: read -r name desc; do
          if [ "$name" = "console" ]; then
            active=$(grep -q "^CONSOLE_ENABLED=1" "$PROJECT_DIR/.env" 2>/dev/null && echo "${GRN}active${NC}" || echo "${DIM}inactive${NC}")
          elif [ "$name" = "git-tracking" ]; then
            active=$(grep -q "^GIT_TRACKING_ENABLED=1" "$PROJECT_DIR/.env" 2>/dev/null && echo "${GRN}active${NC}" || echo "${DIM}inactive${NC}")
          else
            active="${DIM}inactive${NC}"
          fi
          echo -e "  ${CYN}$name${NC}  $desc  [$active]"
        done
        echo ""
        ;;
      enable)
        if [ -z "$PLUGIN" ]; then
          echo -e "${RED}Usage: admin.sh plugin enable <name> [paths...]${NC}" >&2; exit 1
        fi

        # console: toggle env var + restart proxy (respects override for git-tracking)
        if [ "$PLUGIN" = "console" ]; then
          ENV_FILE="$PROJECT_DIR/.env"
          touch "$ENV_FILE"
          if grep -q "^CONSOLE_ENABLED=" "$ENV_FILE" 2>/dev/null; then
            sed -i.bak 's/^CONSOLE_ENABLED=.*/CONSOLE_ENABLED=1/' "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
          else
            echo "CONSOLE_ENABLED=1" >> "$ENV_FILE"
          fi
          CONSOLE_ENABLED=1 $COMPOSE up -d --force-recreate openresty 2>&1
          echo -e "${GRN}Console enabled${NC} — open http://localhost:8888/console"
          exit 0
        fi

        # git-tracking: full service in override + GIT_TRACKING_ENABLED
        if [ "$PLUGIN" = "git-tracking" ]; then
          REPO_PATHS=("$@")
          if [ ${#REPO_PATHS[@]} -eq 0 ]; then
            echo -e "${RED}Usage: admin.sh plugin enable git-tracking <repo-path> [repo-path...]${NC}" >&2
            echo -e "${DIM}  Example: admin.sh plugin enable git-tracking ~/offline_coding ~/servers${NC}" >&2
            exit 1
          fi

          # Resolve all paths first
          VOLUMES=""
          for rpath in "${REPO_PATHS[@]}"; do
            abs="$(cd "$rpath" 2>/dev/null && pwd)" || {
              echo -e "${RED}Path not found: $rpath${NC}" >&2; exit 1
            }
            rname="$(basename "$abs")"
            VOLUMES="${VOLUMES}      - ${abs}:/repos/${rname}:ro
"
            echo -e "  ${DIM}+ ${abs}${NC}"
          done

          # Write complete service definition to override
          cat > "$OVERRIDE" <<YAML
services:
  git-tracking:
    image: alpine:3.19
    container_name: gateii-git-tracking
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    volumes:
      - ./scripts/git-tracking.sh:/app/git-tracking.sh:ro
      - ./data:/data
${VOLUMES}    environment:
      - GIT_AUTHOR=\${GIT_AUTHOR:-}
      - GIT_TRACKING_INTERVAL=\${GIT_TRACKING_INTERVAL:-300}
    entrypoint:
      - /bin/sh
      - -c
      - |
        apk add --no-cache git >/dev/null 2>&1
        exec /bin/sh /app/git-tracking.sh --container
    networks:
      - gateii
YAML

          # Set GIT_TRACKING_ENABLED in .env
          ENV_FILE="$PROJECT_DIR/.env"
          touch "$ENV_FILE"
          if grep -q "^GIT_TRACKING_ENABLED=" "$ENV_FILE" 2>/dev/null; then
            sed -i.bak 's/^GIT_TRACKING_ENABLED=.*/GIT_TRACKING_ENABLED=1/' "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
          else
            echo "GIT_TRACKING_ENABLED=1" >> "$ENV_FILE"
          fi

          # Start with override
          COMPOSE_WITH_OVERRIDE="$COMPOSE -f $OVERRIDE"
          $COMPOSE_WITH_OVERRIDE up -d git-tracking 2>&1
          echo -e "${GRN}Plugin git-tracking enabled${NC}"
          exit 0
        fi

        echo -e "${RED}Unknown plugin: $PLUGIN${NC}" >&2; exit 1
        ;;
      disable)
        if [ -z "$PLUGIN" ]; then
          echo -e "${RED}Usage: admin.sh plugin disable <name>${NC}" >&2; exit 1
        fi
        # console: toggle env var (respects override for git-tracking)
        if [ "$PLUGIN" = "console" ]; then
          ENV_FILE="$PROJECT_DIR/.env"
          touch "$ENV_FILE"
          if grep -q "^CONSOLE_ENABLED=" "$ENV_FILE" 2>/dev/null; then
            sed -i.bak 's/^CONSOLE_ENABLED=.*/CONSOLE_ENABLED=0/' "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
          else
            echo "CONSOLE_ENABLED=0" >> "$ENV_FILE"
          fi
          CONSOLE_ENABLED=0 $COMPOSE up -d --force-recreate openresty 2>&1
          echo -e "${GRN}Console disabled${NC}"
          exit 0
        fi
        # git-tracking: stop container, remove override, set GIT_TRACKING_ENABLED=0
        if [ "$PLUGIN" = "git-tracking" ]; then
          if [ -f "$OVERRIDE" ]; then
            COMPOSE_WITH_OVERRIDE="$COMPOSE -f $OVERRIDE"
            $COMPOSE_WITH_OVERRIDE stop git-tracking 2>/dev/null || true
            $COMPOSE_WITH_OVERRIDE rm -f git-tracking 2>/dev/null || true
          fi
          rm -f "$OVERRIDE" 2>/dev/null || true
          rm -f "$PROJECT_DIR/data/git-metrics.txt" 2>/dev/null || true
          ENV_FILE="$PROJECT_DIR/.env"
          touch "$ENV_FILE"
          if grep -q "^GIT_TRACKING_ENABLED=" "$ENV_FILE" 2>/dev/null; then
            sed -i.bak 's/^GIT_TRACKING_ENABLED=.*/GIT_TRACKING_ENABLED=0/' "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
          else
            echo "GIT_TRACKING_ENABLED=0" >> "$ENV_FILE"
          fi
          echo -e "${GRN}Plugin git-tracking disabled${NC}"
          exit 0
        fi

        echo -e "${RED}Unknown plugin: $PLUGIN${NC}" >&2; exit 1
        ;;
      status)
        echo ""
        echo -e "${BOLD}Plugin status${NC}"
        echo ""
        echo "$PLUGINS" | while IFS=: read -r name desc; do
          if $COMPOSE --profile "$name" ps --format '{{.Name}}' 2>/dev/null | grep -q "gateii-$name"; then
            uptime=$($COMPOSE --profile "$name" ps --format '{{.Status}}' 2>/dev/null | grep "$name" | head -1)
            echo -e "  ${CYN}$name${NC}  ${GRN}active${NC}  ($uptime)"
            # Show mounted repos
            if [ "$name" = "git-tracking" ] && [ -f "$OVERRIDE" ]; then
              grep ':/repos/' "$OVERRIDE" 2>/dev/null | sed 's|.*- ||;s|:/repos/.*||' | while read -r rp; do
                echo -e "    ${DIM}$rp${NC}"
              done
            fi
          else
            echo -e "  ${CYN}$name${NC}  ${DIM}inactive${NC}"
          fi
        done
        echo ""
        ;;
      *)
        echo -e "${RED}Unknown plugin action '$ACTION' — use list, enable, disable, status${NC}" >&2; exit 1
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
    echo "  ${BOLD}Plugins${NC}"
    echo "  plugin list                     Available plugins and status"
    echo "  plugin enable <name>            Start a plugin"
    echo "  plugin disable <name>           Stop a plugin"
    echo "  plugin status                   Detailed plugin status"
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
