#!/bin/bash
# git-stats — optional plugin: export git activity as Prometheus metrics
# Writes to data/git-metrics.txt, served by openresty at /metrics/git
#
# Usage:
#   ./scripts/git-stats.sh ~/projects/repo1 ~/projects/repo2
#   ./scripts/git-stats.sh --watch ~/projects/repo1    # refresh every 5m
#   GIT_AUTHOR="Your Name" ./scripts/git-stats.sh ~/projects/repo1
#
# Disable: stop the script (or delete data/git-metrics.txt)
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${PROJECT_DIR}/data/git-metrics.txt"
AUTHOR="${GIT_AUTHOR:-}"
WATCH=false
INTERVAL=300  # 5 minutes

# Parse flags
REPOS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch) WATCH=true; shift ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --author) AUTHOR="$2"; shift 2 ;;
        *) REPOS+=("$1"); shift ;;
    esac
done

if [[ ${#REPOS[@]} -eq 0 ]]; then
    echo "Usage: git-stats.sh [--watch] [--author NAME] <repo-path> [repo-path...]" >&2
    echo "" >&2
    echo "Exports git activity as Prometheus metrics for the gateii insights dashboard." >&2
    echo "Run with --watch to refresh every 5 minutes." >&2
    exit 1
fi

collect() {
    local tmpfile="${OUTPUT}.tmp"
    {
        echo "# HELP gateii_git_commits_24h Git commits in the last 24 hours"
        echo "# TYPE gateii_git_commits_24h gauge"
        echo "# HELP gateii_git_lines_added_24h Lines added in the last 24 hours"
        echo "# TYPE gateii_git_lines_added_24h gauge"
        echo "# HELP gateii_git_lines_removed_24h Lines removed in the last 24 hours"
        echo "# TYPE gateii_git_lines_removed_24h gauge"
        echo "# HELP gateii_git_files_changed_24h Files changed in the last 24 hours"
        echo "# TYPE gateii_git_files_changed_24h gauge"

        for repo_path in "${REPOS[@]}"; do
            if [[ ! -d "$repo_path/.git" ]]; then
                echo "# skipping $repo_path (not a git repo)" >&2
                continue
            fi

            local repo
            repo=$(basename "$repo_path")

            local author_flag=""
            if [[ -n "$AUTHOR" ]]; then
                author_flag="--author=$AUTHOR"
            fi

            # Commits in last 24h
            local commits
            commits=$(git -C "$repo_path" rev-list --count --since="24 hours ago" $author_flag HEAD 2>/dev/null || echo 0)

            # Lines added/removed and files changed in last 24h
            local added=0 removed=0 files=0
            local stats
            stats=$(git -C "$repo_path" log --shortstat --since="24 hours ago" $author_flag 2>/dev/null || true)
            if [[ -n "$stats" ]]; then
                files=$(echo "$stats" | awk '/files? changed/ { sum += $1 } END { print sum+0 }')
                added=$(echo "$stats" | awk '/files? changed/ { for(i=1;i<=NF;i++) { if($i ~ /insertion/) sum += $(i-1) } } END { print sum+0 }')
                removed=$(echo "$stats" | awk '/files? changed/ { for(i=1;i<=NF;i++) { if($i ~ /deletion/) sum += $(i-1) } } END { print sum+0 }')
            fi

            echo "gateii_git_commits_24h{repo=\"$repo\"} $commits"
            echo "gateii_git_lines_added_24h{repo=\"$repo\"} $added"
            echo "gateii_git_lines_removed_24h{repo=\"$repo\"} $removed"
            echo "gateii_git_files_changed_24h{repo=\"$repo\"} $files"
        done
    } > "$tmpfile"
    mv "$tmpfile" "$OUTPUT"
}

mkdir -p "$(dirname "$OUTPUT")"

if [[ "$WATCH" == true ]]; then
    echo "git-stats: watching ${#REPOS[@]} repo(s), refreshing every ${INTERVAL}s"
    echo "  output: $OUTPUT"
    echo "  stop with Ctrl+C or kill this process"
    while true; do
        collect
        sleep "$INTERVAL"
    done
else
    collect
    echo "git-stats: wrote metrics to $OUTPUT (${#REPOS[@]} repo(s))"
fi
