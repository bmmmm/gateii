#!/bin/bash
# deploy-nutc — push gateii stack to the NUTC host.
#
# rsync flow:
#   1. docker-compose.yml + README     → ~/docker/gateii/
#   2. config/openresty/, prometheus.yml, grafana/  → ~/docker/gateii/config/...
#   3. docker compose up -d
#
# Preserves .env and data/ on the host (never overwritten).
# --inplace is used for every rsync so Docker bind-mount inodes stay stable.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

SSH_HOST="${GATEII_SSH_HOST:-nutc}"
REMOTE_DIR="${GATEII_REMOTE_DIR:-~/docker/gateii}"

red()  { printf '\033[0;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

die() { red "✗ $*" >&2; exit 1; }

command -v rsync >/dev/null 2>&1 || die "rsync is required"
command -v ssh   >/dev/null 2>&1 || die "ssh is required"

bold "gateii → $SSH_HOST:$REMOTE_DIR"

# Sanity: ssh works
ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_HOST" "echo ok" >/dev/null \
    || die "cannot ssh to $SSH_HOST (need passwordless login)"

# Local validation — don't push a broken compose file.
# Stub the required-in-prod vars so local validation doesn't need a real .env.
dim "  validating docker-compose.yml locally..."
ADMIN_TOKEN=stub GRAFANA_ADMIN_PASSWORD=stub \
    docker compose -f servers/nutc/server/stacks/gateii/docker-compose.yml config \
    >/dev/null 2>&1 \
    || die "compose validation failed — run: ADMIN_TOKEN=x GRAFANA_ADMIN_PASSWORD=x docker compose -f servers/nutc/server/stacks/gateii/docker-compose.yml config"

dim "  ensuring remote dir..."
ssh "$SSH_HOST" "mkdir -p $REMOTE_DIR/config/prometheus $REMOTE_DIR/config/grafana $REMOTE_DIR/data"

# 1. compose + README
dim "  [1/4] docker-compose.yml + README"
rsync -az --inplace \
    servers/nutc/server/stacks/gateii/docker-compose.yml \
    servers/nutc/server/stacks/gateii/README.md \
    "$SSH_HOST:$REMOTE_DIR/"

# 2. openresty config (lua + nginx.conf + html)
dim "  [2/4] config/openresty/"
rsync -az --inplace --delete \
    config/openresty/ \
    "$SSH_HOST:$REMOTE_DIR/config/openresty/"

# 3. prometheus.yml + alerts
dim "  [3/4] prometheus config"
rsync -az --inplace \
    prometheus.yml \
    "$SSH_HOST:$REMOTE_DIR/config/prometheus.yml"
if [ -d config/prometheus ]; then
    rsync -az --inplace --delete \
        config/prometheus/ \
        "$SSH_HOST:$REMOTE_DIR/config/prometheus/"
fi

# 4. grafana provisioning + dashboards
dim "  [4/4] grafana provisioning + dashboards"
rsync -az --inplace --delete \
    grafana/ \
    "$SSH_HOST:$REMOTE_DIR/config/grafana/"

# Check .env exists on the remote
if ! ssh "$SSH_HOST" "test -f $REMOTE_DIR/.env"; then
    red "⚠ no .env on remote — copy .env.example and fill it in before starting:"
    echo "    ssh $SSH_HOST 'cp $REMOTE_DIR/docker-compose.yml $REMOTE_DIR/.env.example'"
    echo "    ssh $SSH_HOST 'nano $REMOTE_DIR/.env'"
    exit 1
fi

bold "  → docker compose up -d"
ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose up -d"

echo ""
dim "  waiting 5s for containers to settle..."
sleep 5
ssh "$SSH_HOST" "cd $REMOTE_DIR && docker compose ps"

echo ""
grn "✓ deploy complete"
dim "  smoke-test: ssh $SSH_HOST curl -sf http://127.0.0.1:\${PROXY_PORT:-8888}/health"
