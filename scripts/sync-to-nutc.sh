#!/usr/bin/env bash
# Fallback deploy: rsync repo contents to nutc when git pull isn't available
# (e.g. git.home unreachable, deploy-key rotation pending).
#
# Requires: SSH alias `nutc` configured in ~/.ssh/config.
#
# Preserves on nutc: .env, data/, .git/, backup-*
# Syncs to nutc:     config/, scripts/, docker-compose.yml, README.md
#
# After sync, trigger reload manually on nutc:
#   ssh nutc /home/bmadmin/docker/gateii/scripts/update.sh --force

set -euo pipefail

REMOTE_HOST="${GATEII_REMOTE_HOST:-nutc}"
REMOTE_PATH="${GATEII_REMOTE_PATH:-/home/bmadmin/docker/gateii}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

DRY_RUN=""
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN="--dry-run"
  echo "(dry-run mode — no files written)"
fi

echo "Syncing $REPO_DIR/ -> $REMOTE_HOST:$REMOTE_PATH/ ..."

rsync -rlptz --inplace --delete $DRY_RUN \
  --exclude='.env' \
  --exclude='.env.local' \
  --exclude='data/' \
  --exclude='.git/' \
  --exclude='tmp/' \
  --exclude='node_modules/' \
  --exclude='backup-*' \
  --exclude='.claude/' \
  --exclude='.DS_Store' \
  ./config ./scripts ./docker-compose.yml ./README.md \
  "$REMOTE_HOST:$REMOTE_PATH/"

echo ""
echo "Synced. Next step on $REMOTE_HOST:"
echo "  ssh $REMOTE_HOST $REMOTE_PATH/scripts/update.sh --force"
