#!/usr/bin/env bash
# Configure this repository so Claude can commit + push under a separate
# identity. Forgejo Push is HTTP-with-token (Sandbox blocks all outgoing
# SSH on TCP level — even to allow-listed hosts), authenticated against
# your-org's user token, but commits are signed as Claude.
#
# Run manually once per repo. Claude itself cannot run `git config` (that
# class of subcommand is sandbox-blocked).
#
# Prerequisites (one-time, on Forgejo):
#   - your-org must have a personal-access token (already in tea config).
#   - The repo must exist on Forgejo (whoever creates it: your-org manually,
#     or via fj/tea/API in a separate step).
#
# What this script sets, scoped to this repo only:
#   - user.name, user.email           → "Claude (<repo>)" / claude@local
#   - remote.origin.url                → https://forgejo.example.com/<owner>/<repo>.git
#   - credential.helper                → store --file=~/.config/claudii/git-credentials
#                                        (file is created if missing, mode 600,
#                                         token sourced from tea config.yml)
#
# After this runs, Claude can `git push` without sandbox bypass.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_NAME=$(basename "$PWD")
TEA_CONFIG="$HOME/Library/Application Support/tea/config.yml"
CRED_FILE="$HOME/.config/claudii/git-credentials"

if [[ ! -f "$TEA_CONFIG" ]]; then
  echo "Missing tea config at $TEA_CONFIG — install + login tea first." >&2
  exit 1
fi

TOKEN=$(awk '/^[[:space:]]*token:/ {print $2; exit}' "$TEA_CONFIG")
if [[ -z "$TOKEN" ]]; then
  echo "No token found in $TEA_CONFIG." >&2
  exit 1
fi

# Find Forgejo user from tea config (the one whose token we use)
TEA_USER=$(awk '/^[[:space:]]*user:/ {print $2; exit}' "$TEA_CONFIG")
[[ -z "$TEA_USER" ]] && TEA_USER=your-org

# Detect current remote owner; if not set yet (fresh clone), assume tea_user
CURRENT_URL=$(git remote get-url origin 2>/dev/null || true)
if [[ "$CURRENT_URL" =~ /([^/]+)/([^/]+)\.git$ ]] || [[ "$CURRENT_URL" =~ /([^/]+)/([^/]+)$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO_FROM_URL="${BASH_REMATCH[2]%.git}"
else
  OWNER="$TEA_USER"
  REPO_FROM_URL="$REPO_NAME"
fi

mkdir -p "$(dirname "$CRED_FILE")"
chmod 700 "$(dirname "$CRED_FILE")"
if [[ ! -f "$CRED_FILE" ]] || ! grep -q "@forgejo.example.com" "$CRED_FILE"; then
  # git's `store` helper expects a plain URL per line, NOT `url=` prefix
  echo "https://${TEA_USER}:${TOKEN}@forgejo.example.com" > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
fi

git config --local user.name "Claude (${REPO_NAME})"
git config --local user.email "claude@local"
git config --local credential.helper "store --file=${CRED_FILE}"
git config --local --unset core.sshCommand 2>/dev/null || true

NEW_URL="https://forgejo.example.com/${OWNER}/${REPO_FROM_URL}.git"
if [[ "$CURRENT_URL" != "$NEW_URL" ]]; then
  git remote set-url origin "$NEW_URL"
  echo "  remote: $CURRENT_URL"
  echo "       → $NEW_URL"
fi

echo
echo "Configured ${REPO_NAME} for Claude:"
git config --local --get user.name
git config --local --get user.email
echo "  credential file: $CRED_FILE (mode 600, off-screen)"
echo "  remote: $(git remote get-url origin)"
echo
echo "If this is a brand-new repo, also add a Forgejo deploy key for browsing:"
echo "  https://forgejo.example.com/${OWNER}/${REPO_FROM_URL}/settings/keys"
