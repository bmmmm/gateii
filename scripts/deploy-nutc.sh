#!/usr/bin/env bash
# Deploy gateii's proxy to nutc — openresty only.
#
# nutc convention (see ~/servers/nutc/CLAUDE.md): no per-stack Prometheus or
# Grafana on the server — the garage Prometheus scrapes exporters directly.
# So only the proxy service runs there; add a scrape job for
# <nutc>:8888/metrics on garage. This repo stays the single source of truth:
# the script pushes compose + config to ~/docker/gateii and (re)starts the
# proxy service alone. Server-side state (data/, .env) is never overwritten —
# .env is seeded from the local one on first deploy only.
#
# Usage: scripts/deploy-nutc.sh [--dry-run]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_CONF="${NUTC_SERVER_CONF:-$HOME/servers/nutc/server.conf}"
[ -f "$SERVER_CONF" ] || { echo "Error: $SERVER_CONF missing — clone the nutc server repo first" >&2; exit 1; }
# shellcheck source=/dev/null
. "$SERVER_CONF"
SSH_DEST="${SERVER_USER}@${SERVER_HOST}"   # user@IP: works without ~/.ssh/config reads
DEST="docker/gateii"
DRY_RUN="${1:-}"

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "Would rsync docker-compose.yml + config/ to $SSH_DEST:$DEST, seed .env if absent, compose up -d openresty"
  exit 0
fi

echo "=== gateii → nutc ($SSH_DEST) ==="
ssh "$SSH_DEST" "echo ok" >/dev/null || { echo "Error: cannot reach $SSH_DEST" >&2; exit 1; }

echo "[1] Pushing compose + config ..."
ssh "$SSH_DEST" "mkdir -p $DEST/config $DEST/data && chmod 1777 $DEST/data"
rsync -rltz --omit-dir-times --delete \
  "$ROOT/config/" "$SSH_DEST:$DEST/config/"
rsync -ltz "$ROOT/docker-compose.yml" "$SSH_DEST:$DEST/docker-compose.yml"

echo "[2] Seeding server state (first deploy only) ..."
# .env holds the upstream keys; seed once, never overwrite (server-owned after
# that). Values never pass through this shell's output.
if ! ssh "$SSH_DEST" "test -f $DEST/.env"; then
  [ -f "$ROOT/.env" ] || { echo "Error: local .env missing — nothing to seed the server from" >&2; exit 1; }
  scp -q "$ROOT/.env" "$SSH_DEST:$DEST/.env"
  ssh "$SSH_DEST" "chmod 600 $DEST/.env"
  echo "  -> seeded .env from local"
fi
# Server-specific env: bind beyond loopback (LAN clients + garage scraper),
# console on. sed-replace if present, append if not — values are not secrets.
for kv in "PROXY_BIND=0.0.0.0" "CONSOLE_ENABLED=1"; do
  k="${kv%%=*}"
  ssh "$SSH_DEST" "grep -q '^$k=' $DEST/.env && sed -i 's/^$k=.*/$kv/' $DEST/.env || echo '$kv' >> $DEST/.env"
done
# Free-tier routes config: seed once if the server has none.
if [ -f "$ROOT/data/openrouter-free.json" ]; then
  ssh "$SSH_DEST" "test -f $DEST/data/openrouter-free.json" \
    || scp -q "$ROOT/data/openrouter-free.json" "$SSH_DEST:$DEST/data/openrouter-free.json"
fi

echo "[3] Starting proxy (openresty only) ..."
# --force-recreate: nginx.conf is a single-file bind mount — without a
# recreate the container keeps serving the old inode after every edit.
ssh "$SSH_DEST" "cd $DEST && docker compose up -d --force-recreate openresty"

echo "[4] Health ..."
for _ in 1 2 3 4 5 6; do
  sleep 2
  if OUT="$(ssh "$SSH_DEST" "curl -sf --max-time 3 http://127.0.0.1:8888/health" 2>/dev/null)"; then
    echo "  -> $OUT"
    echo "=== done — proxy at http://$SERVER_HOST:8888 (LAN) ==="
    exit 0
  fi
done
echo "Error: proxy did not become healthy — check: ssh $SSH_DEST 'cd $DEST && docker compose logs openresty | tail -30'" >&2
exit 1
