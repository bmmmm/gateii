#!/bin/bash
# gateii smoke test — verifies the full local stack is up and healthy
set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# Auto-detect Docker socket (handles Colima on macOS)
if [ -z "${DOCKER_HOST:-}" ]; then
  COLIMA_SOCK="$HOME/.colima/default/docker.sock"
  if [ -S "$COLIMA_SOCK" ]; then
    export DOCKER_HOST="unix://$COLIMA_SOCK"
  fi
fi

PASS=0; FAIL=0

ok()   { echo -e "  ${GRN}✓${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "  ${DIM}  $1${NC}"; }

echo ""
echo -e "${BOLD}gateii smoke test${NC}"
echo ""

# --- Container health ---
echo -e "${BOLD}Containers${NC}"
for CONTAINER in gateii-proxy gateii-redis gateii-exporter gateii-prometheus gateii-grafana; do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")
  if [ "$STATUS" = "healthy" ]; then
    ok "$CONTAINER — healthy"
  elif [ "$STATUS" = "missing" ]; then
    fail "$CONTAINER — not found"
  else
    fail "$CONTAINER — $STATUS"
  fi
done

echo ""

# --- Proxy ---
echo -e "${BOLD}Proxy :8888${NC}"
HEALTH=$(curl -sf http://localhost:8888/health 2>/dev/null || echo "")
if [ "$HEALTH" = "ok" ]; then
  ok "/health → ok"
else
  fail "/health → '${HEALTH:-no response}'"
fi

# Test request (passthrough — uses whatever ANTHROPIC_API_KEY or OAuth is set)
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST http://localhost:8888/v1/messages \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
    2>/dev/null || echo "000")
  if [ "$HTTP" = "200" ]; then
    ok "test request → 200"
  else
    fail "test request → $HTTP"
    info "Set ANTHROPIC_API_KEY to test end-to-end"
  fi
else
  echo -e "  ${DIM}⊘  skipping end-to-end request — ANTHROPIC_API_KEY not set${NC}"
fi

echo ""

# --- Exporter / Prometheus metrics ---
echo -e "${BOLD}Exporter :9091${NC}"
METRICS=$(curl -sf http://localhost:9091/metrics 2>/dev/null || echo "")
if echo "$METRICS" | grep -q "# HELP gateii_requests_total"; then
  ok "/metrics — gateii_requests_total present"
else
  fail "/metrics — gateii metrics missing"
fi
if echo "$METRICS" | grep -q "# HELP gateii_cost_dollars_total"; then
  ok "/metrics — gateii_cost_dollars_total present"
else
  fail "/metrics — gateii_cost_dollars_total missing"
fi

echo ""

# --- Prometheus ---
echo -e "${BOLD}Prometheus :9090${NC}"
PROM=$(curl -sf "http://localhost:9090/api/v1/query?query=up" 2>/dev/null || echo "")
if echo "$PROM" | grep -q '"status":"success"'; then
  ok "API responding"
else
  fail "API not responding"
fi

# Check gateii scrape target is up
TARGET=$(curl -sf "http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22gateii%22%7D" 2>/dev/null || echo "")
if echo "$TARGET" | grep -q '"value":\[.*,"1"\]'; then
  ok "gateii scrape target — up"
else
  fail "gateii scrape target — down or not found"
  info "Prometheus may not have scraped yet (wait ~15s)"
fi

echo ""

# --- Grafana ---
echo -e "${BOLD}Grafana :3001${NC}"
GF_HEALTH=$(curl -sf http://localhost:3001/api/health 2>/dev/null || echo "")
GF_DB=$(echo "$GF_HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('database',''))" 2>/dev/null || echo "")
if [ "$GF_DB" = "ok" ]; then
  ok "API healthy"
else
  fail "API not responding"
fi

DASHBOARD=$(curl -sf http://localhost:3001/api/dashboards/uid/gateii-proxy 2>/dev/null || echo "")
DASH_UID=$(echo "$DASHBOARD" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('dashboard',{}).get('uid',''))" 2>/dev/null || echo "")
if [ "$DASH_UID" = "gateii-proxy" ]; then
  TITLE=$(echo "$DASHBOARD" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['dashboard']['title'])" 2>/dev/null || echo "?")
  ok "dashboard loaded — \"$TITLE\""
else
  fail "dashboard not found (uid: gateii-proxy)"
  info "Grafana may still be provisioning — retry in 10s"
fi

DS=$(curl -sf http://localhost:3001/api/datasources 2>/dev/null || echo "")
if echo "$DS" | grep -q '"type":"prometheus"'; then
  ok "Prometheus datasource provisioned"
else
  fail "Prometheus datasource missing"
fi

echo ""

# --- Summary ---
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GRN}${BOLD}All $TOTAL checks passed.${NC}"
  echo -e "  Grafana:  ${DIM}http://localhost:3001${NC}"
  echo -e "  Proxy:    ${DIM}http://localhost:8888${NC}"
  echo -e "  Metrics:  ${DIM}http://localhost:9091/metrics${NC}"
else
  echo -e "${RED}${BOLD}$FAIL/$TOTAL checks failed.${NC}"
  exit 1
fi
echo ""
