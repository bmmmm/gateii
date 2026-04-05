#!/bin/sh
# git-stats — optional plugin: export git activity as Prometheus metrics
#
# Container mode (via docker compose --profile git-stats):
#   Scans /repos for git repos, writes to /data/git-metrics.txt in a loop.
#   Configure GIT_REPOS_PATH and GIT_AUTHOR in .env.
#
# Host mode:
#   ./scripts/git-stats.sh ~/projects/repo1 ~/projects/repo2
#   ./scripts/git-stats.sh --watch ~/projects/repo1
set -eu

# Defaults (overridden by env vars in container mode)
AUTHOR="${GIT_AUTHOR:-}"
INTERVAL="${GIT_STATS_INTERVAL:-300}"

collect() {
    repos_dir="$1"
    output="$2"
    tmpfile="${output}.tmp"

    {
        echo "# HELP gateii_git_commits_24h Git commits in the last 24 hours"
        echo "# TYPE gateii_git_commits_24h gauge"
        echo "# HELP gateii_git_lines_added_24h Lines added in the last 24 hours"
        echo "# TYPE gateii_git_lines_added_24h gauge"
        echo "# HELP gateii_git_lines_removed_24h Lines removed in the last 24 hours"
        echo "# TYPE gateii_git_lines_removed_24h gauge"
        echo "# HELP gateii_git_files_changed_24h Files changed in the last 24 hours"
        echo "# TYPE gateii_git_files_changed_24h gauge"

        find -L "$repos_dir" -maxdepth 3 -name ".git" -type d 2>/dev/null | while read -r gitdir; do
            repo_path="$(dirname "$gitdir")"
            repo="$(basename "$repo_path")"

            author_flag=""
            if [ -n "$AUTHOR" ]; then
                author_flag="--author=$AUTHOR"
            fi

            commits=$(git -C "$repo_path" rev-list --count --since="24 hours ago" $author_flag HEAD 2>/dev/null || echo 0)

            added=0; removed=0; files=0
            stats=$(git -C "$repo_path" log --shortstat --since="24 hours ago" $author_flag 2>/dev/null || true)
            if [ -n "$stats" ]; then
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
    mv "$tmpfile" "$output"
}

# --- Container mode ---
if [ "${1:-}" = "--container" ]; then
    OUTPUT="/data/git-metrics.txt"
    REPOS="/repos"

    if [ ! -d "$REPOS" ] || [ "$(find -L "$REPOS" -maxdepth 3 -name '.git' -type d 2>/dev/null | head -1)" = "" ]; then
        echo "git-stats: no git repos found in $REPOS" >&2
        echo "  Set GIT_REPOS_PATH in .env to the parent directory of your repos" >&2
        exit 1
    fi

    repo_count=$(find -L "$REPOS" -maxdepth 3 -name ".git" -type d 2>/dev/null | wc -l | tr -d ' ')
    echo "git-stats: watching $repo_count repo(s), refreshing every ${INTERVAL}s"

    while true; do
        collect "$REPOS" "$OUTPUT"
        sleep "$INTERVAL"
    done
fi

# --- Host mode ---
if [ $# -eq 0 ]; then
    echo "Usage: git-stats.sh [--watch] [repo-path ...]" >&2
    echo "" >&2
    echo "  Standalone:  ./scripts/git-stats.sh ~/projects/repo1" >&2
    echo "  Watch mode:  ./scripts/git-stats.sh --watch ~/projects/repo1" >&2
    echo "  As plugin:   Set GIT_REPOS_PATH in .env, then:" >&2
    echo "               docker compose --profile git-stats up -d" >&2
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${PROJECT_DIR}/data/git-metrics.txt"
mkdir -p "$(dirname "$OUTPUT")"

WATCH=false
if [ "${1:-}" = "--watch" ]; then
    WATCH=true
    shift
fi

# Create a temp directory with symlinks so collect() can scan it
TMPDIR_REPOS=$(mktemp -d)
trap 'rm -rf "$TMPDIR_REPOS"' EXIT
for repo in "$@"; do
    if [ -d "$repo/.git" ]; then
        ln -sf "$(cd "$repo" && pwd)" "$TMPDIR_REPOS/$(basename "$repo")"
    else
        echo "skipping $repo (not a git repo)" >&2
    fi
done

if [ "$WATCH" = true ]; then
    repo_count=$(find "$TMPDIR_REPOS" -maxdepth 1 -type l | wc -l | tr -d ' ')
    echo "git-stats: watching $repo_count repo(s), refreshing every ${INTERVAL}s"
    echo "  output: $OUTPUT"
    while true; do
        collect "$TMPDIR_REPOS" "$OUTPUT"
        sleep "$INTERVAL"
    done
else
    collect "$TMPDIR_REPOS" "$OUTPUT"
    repo_count=$(find "$TMPDIR_REPOS" -maxdepth 1 -type l | wc -l | tr -d ' ')
    echo "git-stats: wrote metrics for $repo_count repo(s) to $OUTPUT"
fi
