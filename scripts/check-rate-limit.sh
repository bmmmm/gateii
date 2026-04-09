#!/bin/bash
# check-rate-limit.sh — show Anthropic rate limit state from /metrics
COLIMA_SOCK="$HOME/.colima/default/docker.sock"
if [ -z "${DOCKER_HOST:-}" ] && [ -S "$COLIMA_SOCK" ]; then
    export DOCKER_HOST="unix://$COLIMA_SOCK"
fi

PROXY="${PROXY_URL:-http://localhost:8888}"
METRICS=$(curl -sf --max-time 5 "$PROXY/metrics" 2>/dev/null)
if [ -z "$METRICS" ]; then
    echo "ERROR: cannot reach $PROXY/metrics" >&2
    exit 1
fi

DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'
GRN='\033[0;32m'; YEL='\033[1;33m'; RED='\033[0;31m'; CYN='\033[0;36m'

# --- helpers ---
fmt_secs() {
    local secs=${1%.*}
    local h=$((secs / 3600))
    local m=$(( (secs % 3600) / 60 ))
    local s=$((secs % 60))
    if [ "$h" -gt 0 ]; then printf "%dh %02dm" "$h" "$m"
    else printf "%dm %02ds" "$m" "$s"
    fi
}

bar() {
    # usage: bar <pct_int> <width>  → filled/empty bar
    local pct=$1 width=${2:-20}
    local filled=$(( pct * width / 100 ))
    local empty=$((width - filled))
    printf '%0.s█' $(seq 1 $filled 2>/dev/null) 2>/dev/null || true
    printf '%0.s░' $(seq 1 $empty 2>/dev/null) 2>/dev/null || true
}

# --- read metrics ---
gv() { echo "$METRICS" | grep "^$1 " | awk '{print $2}' || true; }

REMAINING=$(gv gateii_rate_limit_tokens_remaining)
RESET_SECS=$(gv gateii_rate_limit_seconds_until_reset)
TOKENS_MAX=$(gv gateii_rate_limit_tokens_max)
EXPIRED=$(gv gateii_rate_limit_tokens_expired)
UTIL_5H=$(gv gateii_rate_limit_5h_utilization)
UTIL_7D=$(gv gateii_rate_limit_7d_utilization)
RESET_7D_SECS=$(gv gateii_rate_limit_7d_seconds_until_reset)
FALLBACK=$(gv gateii_rate_limit_fallback_pct)

if [ -z "$UTIL_5H" ] && [ -z "$REMAINING" ]; then
    echo ""
    echo -e "${YEL}No rate limit data yet${NC}"
    echo -e "${DIM}Send one request through the proxy, then rerun.${NC}"
    echo ""
    exit 0
fi

echo ""
echo -e "${BOLD}Anthropic Rate Limit State${NC}"
echo ""

# --- 5h window ---
echo -e "  ${BOLD}5-hour window${NC}"
if [ -n "$UTIL_5H" ]; then
    PCT_5H=$(awk "BEGIN{printf \"%d\", $UTIL_5H*100}")
    if   [ "$PCT_5H" -lt 60 ]; then COLOR=$GRN
    elif [ "$PCT_5H" -lt 85 ]; then COLOR=$YEL
    else                            COLOR=$RED; fi
    BAR=$(bar "$PCT_5H" 24)
    echo -e "    ${DIM}used:${NC}    ${COLOR}${BAR}${NC} ${BOLD}${PCT_5H}%${NC}"
fi
if [ -n "$REMAINING" ] && [ -n "$TOKENS_MAX" ] && [ "$TOKENS_MAX" != "0" ]; then
    REM=${REMAINING%.*}
    MAX=${TOKENS_MAX%.*}
    echo -e "    ${DIM}remaining:${NC} ${BOLD}$(printf "%'d" "$REM")${NC} ${DIM}/ $(printf "%'d" "$MAX") tokens${NC}"
fi
if [ -n "$RESET_SECS" ]; then
    SECS=${RESET_SECS%.*}
    if   [ "$SECS" -gt 3600 ]; then COLOR=$GRN
    elif [ "$SECS" -gt 600  ]; then COLOR=$YEL
    else                            COLOR=$RED; fi
    echo -e "    ${DIM}resets in:${NC} ${COLOR}$(fmt_secs "$SECS")${NC}"
fi

# --- 7d window ---
if [ -n "$UTIL_7D" ]; then
    echo ""
    echo -e "  ${BOLD}7-day window${NC}"
    PCT_7D=$(awk "BEGIN{printf \"%d\", $UTIL_7D*100}")
    if   [ "$PCT_7D" -lt 60 ]; then COLOR=$GRN
    elif [ "$PCT_7D" -lt 85 ]; then COLOR=$YEL
    else                            COLOR=$RED; fi
    BAR=$(bar "$PCT_7D" 24)
    echo -e "    ${DIM}used:${NC}    ${COLOR}${BAR}${NC} ${BOLD}${PCT_7D}%${NC}"
    if [ -n "$RESET_7D_SECS" ]; then
        SECS7=${RESET_7D_SECS%.*}
        echo -e "    ${DIM}resets in:${NC} ${CYN}$(fmt_secs "$SECS7")${NC}"
    fi
fi

# --- fallback ---
if [ -n "$FALLBACK" ]; then
    echo ""
    FB_PCT=$(awk "BEGIN{printf \"%d\", $FALLBACK*100}")
    if [ "$FB_PCT" -gt 0 ]; then
        echo -e "  ${DIM}fallback capacity:${NC}  ${GRN}+${FB_PCT}%${NC} ${DIM}extra tokens available after 5h limit${NC}"
    fi
fi

# --- expired last reset ---
if [ -n "$EXPIRED" ] && [ "${EXPIRED%.*}" != "0" ]; then
    echo ""
    echo -e "  ${DIM}unused at last reset:${NC} ${YEL}$(printf "%'d" "${EXPIRED%.*}")${NC} ${DIM}tokens${NC}"
fi

echo ""

# --- rate limit hit events ---
WAITS=$(echo "$METRICS" | grep "^gateii_rate_limit_wait_seconds{" || true)
if [ -n "$WAITS" ]; then
    echo -e "${BOLD}Rate Limit Hit Events${NC}"
    echo ""
    echo "$WAITS" | while IFS= read -r line; do
        echo -e "  ${DIM}$line${NC}"
    done
    echo ""
fi
