#!/bin/bash
# gateii-connect — provision a proxy key via bootstrap handshake.
#
# Required env:
#   GATEII_URL              base URL of the proxy, e.g. https://gateii.example.com
#   GATEII_BOOTSTRAP_CODE   one-time code from `admin.sh bootstrap create`
#   GATEII_BOOTSTRAP_SECRET 32-byte hex HMAC secret from the same invocation
#
# Optional env:
#   GATEII_SETTINGS         Claude settings path (default: ~/.claude/settings.json)
#   GATEII_DRY_RUN=1        perform handshake, print result, do NOT touch settings
#
# Flow: challenge → exchange (receive api_key + confirm_token) → install into
# settings.json (with backup) → verify via /health → confirm install-or-revoke.
#
# Requires: curl, jq, openssl.

set -euo pipefail

red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
grn()   { printf '\033[0;32m%s\033[0m\n' "$*"; }
yel()   { printf '\033[1;33m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

die() { red "✗ $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 not installed — install it and retry"; }
need curl; need jq; need openssl

URL="${GATEII_URL:?Set GATEII_URL=https://gateii.example.com}"
CODE="${GATEII_BOOTSTRAP_CODE:?Set GATEII_BOOTSTRAP_CODE=btp_...}"
SECRET="${GATEII_BOOTSTRAP_SECRET:?Set GATEII_BOOTSTRAP_SECRET=<hex>}"
SETTINGS="${GATEII_SETTINGS:-$HOME/.claude/settings.json}"
DRY_RUN="${GATEII_DRY_RUN:-0}"

# HMAC-SHA256(hex-secret, message) → hex digest.
hmac_hex() {
    local msg="$1"
    printf '%s' "$msg" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$SECRET" | awk '{print $NF}'
}

# POST JSON body → stdout. Fails (exit 1) on non-2xx with body on stderr.
post_json() {
    local path="$1"; shift
    local body="$1"; shift
    local tmp; tmp="$(mktemp)"
    local code
    code=$(curl -sS -o "$tmp" -w '%{http_code}' \
                -H 'Content-Type: application/json' \
                -X POST "$URL$path" \
                --data "$body") || { cat "$tmp" >&2; rm -f "$tmp"; die "POST $path failed"; }
    if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
        cat "$tmp" >&2
        rm -f "$tmp"
        die "POST $path → HTTP $code"
    fi
    cat "$tmp"
    rm -f "$tmp"
}

# ---------- Phase 1: challenge ----------
bold "Bootstrap handshake → $URL"
dim "  phase 1/4 — challenge"
CHAL=$(post_json /internal/bootstrap/challenge "$(jq -nc --arg c "$CODE" '{code:$c}')")
NONCE=$(echo "$CHAL" | jq -r '.nonce // empty')
[ -n "$NONCE" ] || die "no nonce in challenge response"

# ---------- Phase 2: exchange ----------
dim "  phase 2/4 — exchange"
PROOF=$(hmac_hex "$CODE:$NONCE")
EXCH=$(post_json /internal/bootstrap/exchange \
    "$(jq -nc --arg c "$CODE" --arg n "$NONCE" --arg p "$PROOF" \
        '{code:$c, nonce:$n, proof:$p}')")
API_KEY=$(echo "$EXCH"   | jq -r '.api_key // empty')
USER=$(echo "$EXCH"      | jq -r '.user // empty')
PROVIDER=$(echo "$EXCH"  | jq -r '.provider // empty')
CONFIRM_TOKEN=$(echo "$EXCH" | jq -r '.confirm_token // empty')
[ -n "$API_KEY" ] && [ -n "$CONFIRM_TOKEN" ] || die "exchange response incomplete"
grn "  ✓ issued key for $USER ($PROVIDER)"

if [ "$DRY_RUN" = "1" ]; then
    yel "  dry-run — skipping settings install + confirm"
    bold "ANTHROPIC_API_KEY=$API_KEY"
    bold "ANTHROPIC_BASE_URL=$URL"
    exit 0
fi

# ---------- Phase 3: install ----------
dim "  phase 3/4 — install into $SETTINGS"
install_status="installed"
install_err=""

# Restore plan: if anything fails between here and confirm, we must say "failed"
# to the proxy so the key gets revoked — never leave a dangling key.
rollback_settings() {
    if [ -f "${SETTINGS}.bak.gateii" ]; then
        mv "${SETTINGS}.bak.gateii" "$SETTINGS" || true
    fi
}

mkdir -p "$(dirname "$SETTINGS")"
if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "${SETTINGS}.bak.gateii"
else
    echo '{}' > "$SETTINGS"
fi

TMP="${SETTINGS}.tmp.gateii"
if ! jq --arg url "$URL" --arg key "$API_KEY" \
    '.env //= {} | .env.ANTHROPIC_BASE_URL = $url | .env.ANTHROPIC_API_KEY = $key' \
    "$SETTINGS" > "$TMP"; then
    rollback_settings
    install_status="failed"
    install_err="jq write failed"
fi
if [ "$install_status" = "installed" ]; then
    if ! mv "$TMP" "$SETTINGS"; then
        rollback_settings
        install_status="failed"
        install_err="mv into place failed"
    fi
fi

# Health check via the new key (only if install succeeded)
if [ "$install_status" = "installed" ]; then
    if ! curl -sf --max-time 5 "$URL/health" >/dev/null 2>&1; then
        # Proxy didn't respond — key install may still be fine, but we cannot verify.
        # Report failed so the key is revoked and the admin can retry.
        rollback_settings
        install_status="failed"
        install_err="health check failed — proxy unreachable"
    fi
fi

# ---------- Phase 4: confirm ----------
dim "  phase 4/4 — confirm (status=$install_status)"
ACK_PROOF=$(hmac_hex "$CONFIRM_TOKEN:$install_status")
CONF=$(post_json /internal/bootstrap/confirm \
    "$(jq -nc --arg t "$CONFIRM_TOKEN" --arg s "$install_status" --arg p "$ACK_PROOF" \
        '{confirm_token:$t, status:$s, proof:$p}')") || true

SERVER_STATUS=$(echo "$CONF" | jq -r '.status // empty')

echo
if [ "$install_status" = "installed" ] && [ "$SERVER_STATUS" = "committed" ]; then
    grn "✓ gateii proxy configured"
    dim "  settings: $SETTINGS (backup: ${SETTINGS}.bak.gateii)"
    dim "  user:     $USER"
    dim "  provider: $PROVIDER"
    dim "  Restart Claude Code to apply."
    exit 0
elif [ "$install_status" = "failed" ]; then
    red "✗ install failed: $install_err"
    red "  server response: ${SERVER_STATUS:-no-response} (key should have been revoked)"
    exit 1
else
    red "✗ unexpected state: install=$install_status server=$SERVER_STATUS"
    exit 1
fi
