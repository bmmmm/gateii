#!/bin/bash
# orchestrate-preflight.sh — pre-flight helper for /orchestrate
# Shows file touches grouped by module for the last N commits
# Usage: ./scripts/orchestrate-preflight.sh [N]   (default: 10)

set -euo pipefail

N="${1:-10}"
MODULES=("lua" "html" "grafana" "scripts" "config" "providers")

echo ""
echo "=== Orchestrate Pre-flight (last $N commits) ==="
echo ""

# Git status
STATUS=$(git status --short | grep -v "^?" || true)
if [ -n "$STATUS" ]; then
    echo "⚠  Dirty working tree — commit before orchestrating:"
    echo "$STATUS"
    echo ""
fi

# Worktree check
ZOMBIES=$(for d in .claude/worktrees/agent-*/; do [ -d "$d" ] && echo "$d"; done 2>/dev/null || true)
if [ -n "$ZOMBIES" ]; then
    echo "⚠  Zombie worktrees found:"
    echo "$ZOMBIES"
    echo "   Run: bash scripts/cleanup-worktree.sh --all"
    echo ""
fi

# Changed files per commit, grouped by module
echo "--- File touches (last $N commits) ---"
echo ""
git log --oneline -"$N" | while read -r hash msg; do
    FILES=$(git diff-tree --no-commit-id -r --name-only "$hash" 2>/dev/null || true)
    [ -z "$FILES" ] && continue
    echo "  $hash  $msg"
    echo "$FILES" | sed 's/^/    /'
    echo ""
done

# Module summary
echo "--- Module summary ---"
echo ""
TOUCHED=$(git diff --name-only HEAD~"$N" HEAD 2>/dev/null || git diff --name-only HEAD~1 HEAD)
for mod in "${MODULES[@]}"; do
    MATCHES=$(echo "$TOUCHED" | grep -i "$mod" || true)
    if [ -n "$MATCHES" ]; then
        COUNT=$(echo "$MATCHES" | wc -l | tr -d ' ')
        echo "  $mod: $COUNT file(s)"
        echo "$MATCHES" | sed 's/^/    /'
    fi
done
echo ""
echo "=== Pre-flight complete — check for overlaps before spawning agents ==="
echo ""
