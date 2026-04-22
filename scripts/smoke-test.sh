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

# Source .env for ADMIN_TOKEN / ANTHROPIC_API_KEY / port config if present
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$PROJECT_DIR/.env" ]; then
  set -a; source "$PROJECT_DIR/.env"; set +a
fi
PROXY_HOST="${PROXY_HOST:-localhost}"
PROXY_PORT="${PROXY_PORT:-8888}"
PROXY="http://${PROXY_HOST}:${PROXY_PORT}"

# Detect --sandbox flag
SANDBOX_MODE=0
for arg in "$@"; do
  if [ "$arg" = "--sandbox" ]; then
    SANDBOX_MODE=1
  fi
done

PASS=0; FAIL=0

ok()   { echo -e "  ${GRN}✓${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "  ${DIM}  $1${NC}"; }

echo ""
echo -e "${BOLD}gateii smoke test${NC}"
if [ "$SANDBOX_MODE" -eq 1 ]; then
  echo -e "${DIM}[sandbox mode — network tests skipped]${NC}"
fi
echo ""

# --- Container health ---
echo -e "${BOLD}Containers${NC}"
for CONTAINER in gateii-proxy gateii-prometheus gateii-grafana; do
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
if [ "$SANDBOX_MODE" -eq 0 ]; then
  HEALTH=$(curl -sf --max-time 5 http://localhost:8888/health 2>/dev/null || echo "")
  # /health returns JSON {"status":"ok", ...} — grep for the status field
  if echo "$HEALTH" | grep -q '"status":"ok"'; then
    ok "/health → ok"
  else
    fail "/health → '${HEALTH:-no response}'"
  fi

  # Test request (passthrough — uses whatever ANTHROPIC_API_KEY or OAuth is set)
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    HTTP=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" \
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
else
  echo -e "  ${DIM}⊘  network tests skipped${NC}"
fi

echo ""

# --- Metrics (from proxy /metrics) ---
echo -e "${BOLD}Metrics :8888/metrics${NC}"
if [ "$SANDBOX_MODE" -eq 0 ]; then
  METRICS=$(curl -sf --max-time 5 http://localhost:8888/metrics 2>/dev/null || echo "")
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
else
  echo -e "  ${DIM}⊘  network tests skipped${NC}"
fi

echo ""

# --- Prometheus ---
echo -e "${BOLD}Prometheus :9090${NC}"
if [ "$SANDBOX_MODE" -eq 0 ]; then
  PROM=$(curl -sf --max-time 5 "http://localhost:9090/api/v1/query?query=up" 2>/dev/null || echo "")
  if echo "$PROM" | grep -q '"status":"success"'; then
    ok "API responding"
  else
    fail "API not responding"
  fi

  # Check gateii scrape target is up
  TARGET=$(curl -sf --max-time 5 "http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22gateii%22%7D" 2>/dev/null || echo "")
  if echo "$TARGET" | grep -q '"value":\[.*,"1"\]'; then
    ok "gateii scrape target — up"
  else
    fail "gateii scrape target — down or not found"
    info "Prometheus may not have scraped yet (wait ~15s)"
  fi
else
  echo -e "  ${DIM}⊘  network tests skipped${NC}"
fi

echo ""

# --- Grafana ---
echo -e "${BOLD}Grafana :3001${NC}"
if [ "$SANDBOX_MODE" -eq 0 ]; then
  GF_HEALTH=$(curl -sf --max-time 5 http://localhost:3001/api/health 2>/dev/null || echo "")
  GF_DB=$(echo "$GF_HEALTH" | jq -r '.database // ""' 2>/dev/null || echo "")
  if [ "$GF_DB" = "ok" ]; then
    ok "API healthy"
  else
    fail "API not responding"
  fi

  # Expect the three provisioned dashboards: operations, cost, efficiency
  DASH_LIST=$(curl -sf --max-time 5 http://localhost:3001/api/search 2>/dev/null || echo "[]")
  MISSING=""
  for DUID in gateii-ops gateii-cost gateii-eff; do
    if ! echo "$DASH_LIST" | jq -e --arg u "$DUID" '.[] | select(.uid==$u)' >/dev/null 2>&1; then
      MISSING="$MISSING $DUID"
    fi
  done
  if [ -z "$MISSING" ]; then
    ok "dashboards provisioned — gateii-ops, gateii-cost, gateii-eff"
  else
    fail "dashboards missing:$MISSING"
    info "Grafana may still be provisioning — retry in 10s"
  fi

  DS=$(curl -sf --max-time 5 http://localhost:3001/api/datasources 2>/dev/null || echo "")
  if echo "$DS" | grep -q '"type":"prometheus"'; then
    ok "Prometheus datasource provisioned"
  else
    fail "Prometheus datasource missing"
  fi
else
  echo -e "  ${DIM}⊘  network tests skipped${NC}"
fi

echo ""

# --- Bootstrap roundtrip (only when ADMIN_TOKEN set and not in sandbox) ---
if [ -n "${ADMIN_TOKEN:-}" ] && [ "$SANDBOX_MODE" -eq 0 ] && command -v openssl >/dev/null 2>&1; then
  echo -e "${BOLD}Bootstrap handshake${NC}"

  # Need an upstream key for the issued proxy key to be usable downstream —
  # we only exercise the handshake here, so a placeholder is fine.
  UPSTREAM_KEY="${ANTHROPIC_API_KEY:-sk-ant-smoke-placeholder}"
  ADMIN_URL="${PROXY}/internal/admin"

  # Phase 0 — admin creates bootstrap
  BS_CREATE=$(curl -sf --max-time 5 -X POST \
    -H "X-Admin-Token: $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"user\":\"smoke-test\",\"provider\":\"anthropic\",\"upstream_key\":\"$UPSTREAM_KEY\",\"ttl\":120}" \
    "$ADMIN_URL/bootstrap" 2>/dev/null || echo "")
  BS_CODE=$(echo "$BS_CREATE"   | jq -r '.code // empty' 2>/dev/null)
  BS_SECRET=$(echo "$BS_CREATE" | jq -r '.secret // empty' 2>/dev/null)

  if [ -z "$BS_CODE" ] || [ -z "$BS_SECRET" ]; then
    fail "admin bootstrap create — no code/secret returned"
    info "response: $BS_CREATE"
  else
    ok "admin bootstrap create — code + secret issued"

    # Phase 1 — challenge
    CHAL=$(curl -sf --max-time 5 -X POST \
      -H "Content-Type: application/json" \
      -d "{\"code\":\"$BS_CODE\"}" \
      "${PROXY}/internal/bootstrap/challenge" 2>/dev/null || echo "")
    NONCE=$(echo "$CHAL" | jq -r '.nonce // empty' 2>/dev/null)
    if [ -n "$NONCE" ]; then
      ok "challenge — nonce issued"

      # Phase 2 — exchange
      PROOF=$(printf '%s' "$BS_CODE:$NONCE" | openssl dgst -sha256 -mac HMAC \
        -macopt "hexkey:$BS_SECRET" | awk '{print $NF}')
      EXCH=$(curl -sf --max-time 5 -X POST \
        -H "Content-Type: application/json" \
        -d "{\"code\":\"$BS_CODE\",\"nonce\":\"$NONCE\",\"proof\":\"$PROOF\"}" \
        "${PROXY}/internal/bootstrap/exchange" 2>/dev/null || echo "")
      API_KEY=$(echo "$EXCH"       | jq -r '.api_key // empty' 2>/dev/null)
      CONFIRM=$(echo "$EXCH"       | jq -r '.confirm_token // empty' 2>/dev/null)

      if [ -n "$API_KEY" ] && [ -n "$CONFIRM" ]; then
        ok "exchange — proxy key issued"

        # Phase 3 — confirm with status=failed so the key is revoked (we do not
        # want a stray sk-proxy-* from every smoke run lingering in keys.json).
        ACK=$(printf '%s' "$CONFIRM:failed" | openssl dgst -sha256 -mac HMAC \
          -macopt "hexkey:$BS_SECRET" | awk '{print $NF}')
        CONF=$(curl -sf --max-time 5 -X POST \
          -H "Content-Type: application/json" \
          -d "{\"confirm_token\":\"$CONFIRM\",\"status\":\"failed\",\"proof\":\"$ACK\"}" \
          "${PROXY}/internal/bootstrap/confirm" 2>/dev/null || echo "")
        if echo "$CONF" | grep -q '"status":"revoked"'; then
          ok "confirm — key revoked after failed status"
        else
          fail "confirm — expected status=revoked, got: $CONF"
        fi
      else
        fail "exchange — no api_key/confirm_token"
        info "response: $EXCH"
      fi
    else
      fail "challenge — no nonce"
      info "response: $CHAL"
    fi
  fi

  echo ""
else
  if [ -z "${ADMIN_TOKEN:-}" ] && [ "$SANDBOX_MODE" -eq 0 ]; then
    echo -e "${DIM}⊘  bootstrap roundtrip — set ADMIN_TOKEN to enable${NC}"
    echo ""
  fi
fi

# --- Summary ---
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GRN}${BOLD}All $TOTAL checks passed.${NC}"
  echo -e "  Grafana:  ${DIM}http://localhost:3001${NC}"
  echo -e "  Proxy:    ${DIM}http://localhost:8888${NC}"
  echo -e "  Metrics:  ${DIM}http://localhost:8888/metrics${NC}"
else
  echo -e "${RED}${BOLD}$FAIL/$TOTAL checks failed.${NC}"
  exit 1
fi
echo ""
