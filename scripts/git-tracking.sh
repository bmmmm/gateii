#!/bin/sh
# git-tracking — optional plugin: export git activity as Prometheus metrics
#
# Container mode (via docker compose --profile git-tracking):
#   Reads /data/git-tracking.json if present (per-repo config).
#   Otherwise scans /repos for git repos.
#   Writes metrics to /data/git-metrics.txt in a loop.
#
# git-tracking.json format:
#   {
#     "default_author": "bma",
#     "interval": 300,
#     "repos": [
#       { "path": "/repos/gateii", "author": "bma", "platform": "forgejo", "alias": "gateii" },
#       { "path": "/repos/other", "platform": "github" }
#     ]
#   }
#   Per-repo author overrides default_author. Platform falls back to
#   detection via `git remote get-url origin` if not set.
#
# Host mode:
#   ./scripts/git-tracking.sh ~/projects/repo1 ~/projects/repo2
#   ./scripts/git-tracking.sh --watch ~/projects/repo1
set -eu

AUTHOR="${GIT_AUTHOR:-}"
INTERVAL="${GIT_TRACKING_INTERVAL:-300}"
CONFIG_PATH="${GIT_TRACKING_CONFIG:-/data/git-tracking.json}"

# Map a remote URL to a known platform tag. Returns "local" if no remote,
# "other" if URL doesn't match any known host.
detect_platform() {
    repo_path="$1"
    url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "")
    case "$url" in
        "")                       echo "local" ;;
        *github.com*)             echo "github" ;;
        *gitlab.com*)             echo "gitlab" ;;
        *codeberg.org*)           echo "codeberg" ;;
        *bitbucket.org*)          echo "bitbucket" ;;
        *forgejo*|*forge.*)       echo "forgejo" ;;
        *gitea*)                  echo "gitea" ;;
        *)                        echo "other" ;;
    esac
}

# Emit metric lines for one repo. Args: path, alias, author (may be empty), platform.
emit_repo() {
    repo_path="$1"; alias="$2"; author="$3"; platform="$4"

    if [ -n "$author" ]; then
        commits=$(git -C "$repo_path" rev-list --count --since="24 hours ago" --author="$author" HEAD 2>/dev/null || echo 0)
        stats=$(git -C "$repo_path"  log --shortstat --since="24 hours ago" --author="$author" 2>/dev/null || true)
    else
        commits=$(git -C "$repo_path" rev-list --count --since="24 hours ago" HEAD 2>/dev/null || echo 0)
        stats=$(git -C "$repo_path"  log --shortstat --since="24 hours ago" 2>/dev/null || true)
    fi

    files=0; added=0; removed=0
    if [ -n "$stats" ]; then
        files=$(echo "$stats"   | awk '/files? changed/ { sum += $1 } END { print sum+0 }')
        added=$(echo "$stats"   | awk '/files? changed/ { for(i=1;i<=NF;i++) { if($i ~ /insertion/) sum += $(i-1) } } END { print sum+0 }')
        removed=$(echo "$stats" | awk '/files? changed/ { for(i=1;i<=NF;i++) { if($i ~ /deletion/)  sum += $(i-1) } } END { print sum+0 }')
    fi

    labels="repo=\"$alias\",platform=\"$platform\""
    echo "gateii_git_commits_24h{$labels} $commits"
    echo "gateii_git_lines_added_24h{$labels} $added"
    echo "gateii_git_lines_removed_24h{$labels} $removed"
    echo "gateii_git_files_changed_24h{$labels} $files"
}

# Iterate repos defined in the config file via jq. One repo per line:
#   <path>\t<alias>\t<author>\t<platform>
# Empty author / platform are filled by emit_repo (platform → detect).
collect_from_config() {
    config="$1"
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

        default_author=$(jq -r '.default_author // ""' "$config")
        jq -r '.repos[]? | [.path, (.alias // ""), (.author // ""), (.platform // "")] | @tsv' "$config" \
            | while IFS="$(printf '\t')" read -r path alias author platform; do
                if [ ! -d "$path/.git" ]; then
                    echo "git-tracking: skipping $path (not a git repo)" >&2
                    continue
                fi
                [ -z "$alias" ]    && alias=$(basename "$path")
                [ -z "$author" ]   && author="$default_author"
                [ -z "$platform" ] && platform=$(detect_platform "$path")
                emit_repo "$path" "$alias" "$author" "$platform"
            done
    } > "$tmpfile"
    mv "$tmpfile" "$output"
}

# Legacy filesystem scan: walk repos_dir, one author for everything,
# auto-detect platform per repo.
collect_from_scan() {
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
            repo_path=$(dirname "$gitdir")
            alias=$(basename "$repo_path")
            platform=$(detect_platform "$repo_path")
            emit_repo "$repo_path" "$alias" "$AUTHOR" "$platform"
        done
    } > "$tmpfile"
    mv "$tmpfile" "$output"
}

# --- Container mode ---
if [ "${1:-}" = "--container" ]; then
    OUTPUT="/data/git-metrics.txt"
    REPOS="/repos"

    trap 'rm -f "${OUTPUT}.tmp"' EXIT INT TERM

    use_config=false
    if [ -s "$CONFIG_PATH" ]; then
        if command -v jq >/dev/null 2>&1; then
            # Config file is present and parseable → use it
            if jq empty "$CONFIG_PATH" >/dev/null 2>&1; then
                use_config=true
                echo "git-tracking: using config $CONFIG_PATH ($(jq -r '.repos | length' "$CONFIG_PATH") repos)"
            else
                echo "git-tracking: $CONFIG_PATH is invalid JSON, falling back to filesystem scan" >&2
            fi
        else
            echo "git-tracking: jq not installed, falling back to filesystem scan" >&2
        fi
    fi

    if [ "$use_config" = false ]; then
        if [ ! -d "$REPOS" ] || [ -z "$(find -L "$REPOS" -maxdepth 3 -name '.git' -type d 2>/dev/null | head -1)" ]; then
            echo "git-tracking: no git repos found in $REPOS" >&2
            echo "  Either set GIT_REPOS_PATH in .env to mount a parent dir," >&2
            echo "  or create $CONFIG_PATH with a repos array." >&2
            exit 1
        fi
        repo_count=$(find -L "$REPOS" -maxdepth 3 -name ".git" -type d 2>/dev/null | wc -l | tr -d ' ')
        echo "git-tracking: scanning $repo_count repo(s) under $REPOS, refresh ${INTERVAL}s"
    fi

    while true; do
        if [ "$use_config" = true ]; then
            collect_from_config "$CONFIG_PATH" "$OUTPUT"
        else
            collect_from_scan "$REPOS" "$OUTPUT"
        fi
        sleep "$INTERVAL"
    done
    exit 0
fi

# --- Host mode ---
if [ $# -eq 0 ]; then
    echo "Usage: git-tracking.sh [--watch] [repo-path ...]" >&2
    echo "" >&2
    echo "  Standalone:  ./scripts/git-tracking.sh ~/projects/repo1" >&2
    echo "  Watch mode:  ./scripts/git-tracking.sh --watch ~/projects/repo1" >&2
    echo "  As plugin:   admin.sh plugin enable git-tracking" >&2
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

# Stage repos via symlinks so collect_from_scan can walk one tree
TMPDIR_REPOS=$(mktemp -d) || { echo "Failed to create temp directory" >&2; exit 1; }
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
    echo "git-tracking: watching $repo_count repo(s), refresh ${INTERVAL}s — output: $OUTPUT"
    while true; do
        collect_from_scan "$TMPDIR_REPOS" "$OUTPUT"
        sleep "$INTERVAL"
    done
else
    collect_from_scan "$TMPDIR_REPOS" "$OUTPUT"
    repo_count=$(find "$TMPDIR_REPOS" -maxdepth 1 -type l | wc -l | tr -d ' ')
    echo "git-tracking: wrote metrics for $repo_count repo(s) to $OUTPUT"
fi
