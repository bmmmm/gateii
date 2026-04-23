#!/usr/bin/env bash
# Pull latest main from git.home and reload affected services.
# Runs on the deployment host (e.g. nutc). Idempotent — safe to re-run.
#
# Usage:
#   ./scripts/update.sh           # fetch + fast-forward pull + smart reload
#   ./scripts/update.sh --dry-run # show what would change, don't pull
#   ./scripts/update.sh --force   # also recreate containers even if compose unchanged

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

DRY_RUN=false
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --force)   FORCE=true ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# //;s/^#//'
      exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# Sanity: must be the gateii repo
if ! git remote get-url origin 2>/dev/null | grep -q "bsz/gateii"; then
  echo "ERROR: origin remote does not point to bsz/gateii" >&2
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
  echo "ERROR: expected branch 'main', on '$BRANCH'" >&2
  exit 1
fi

echo "[$(date +%H:%M:%S)] Fetching origin/main..."
git fetch --quiet origin main

CHANGES="$(git diff --name-only HEAD origin/main || true)"
if [[ -z "$CHANGES" ]]; then
  echo "Already up to date ($(git rev-parse --short HEAD))."
  exit 0
fi

echo "Pending changes ($(git rev-list --count HEAD..origin/main) commit(s)):"
echo "$CHANGES" | sed 's/^/  /'

if $DRY_RUN; then
  echo "(dry-run — no changes applied)"
  exit 0
fi

# Refuse if working tree is dirty — don't clobber local edits
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: working tree has uncommitted changes. Stash or reset first." >&2
  git status --short >&2
  exit 1
fi

echo "Pulling..."
git pull --ff-only origin main

# Decide reload actions based on which files changed
need_compose=false
need_openresty_reload=false
need_grafana_wait=false

while IFS= read -r file; do
  case "$file" in
    docker-compose.yml)               need_compose=true ;;
    config/openresty/*)               need_openresty_reload=true ;;
    config/prometheus/*)              need_compose=true ;;
    config/grafana/dashboards/*)      need_grafana_wait=true ;;
    config/grafana/provisioning/*)    need_compose=true ;;
  esac
done <<< "$CHANGES"

if $FORCE; then need_compose=true; fi

if $need_compose; then
  echo "Running docker compose up -d..."
  docker compose up -d
fi

if $need_openresty_reload; then
  echo "Reloading openresty..."
  docker exec gateii-proxy openresty -s reload
fi

if $need_grafana_wait; then
  echo "Grafana dashboards updated — provisioner picks them up within 30s (no restart needed)."
fi

echo "[$(date +%H:%M:%S)] Done. Now at $(git rev-parse --short HEAD)."
