# Pre-up hooks

gateii's `scripts/up.sh` is platform-agnostic by default. If your environment
needs setup before `docker compose up` — starting a container-runtime VM,
unlocking a credential store, mounting a remote filesystem, whatever — point
`GATEII_PREUP_HOOK` in `.env` at a hook script and it runs first.

## Enable a hook

In `.env`:

```ini
GATEII_PREUP_HOOK=scripts/hooks/colima.sh
```

Paths are resolved relative to the project root. Absolute paths also work.

Leave `GATEII_PREUP_HOOK` unset (or absent) on plain Docker setups — Linux
with native Docker, Docker Desktop on macOS/Windows, Rancher Desktop, etc.
No hook runs, `up.sh` goes straight to `docker compose up -d`.

## Shipped hooks

| File | Platform | What it does |
|------|----------|--------------|
| [`colima.sh`](colima.sh) | macOS + Colima | Ensures the Colima VM is running (`colima start` if needed) and exports `DOCKER_HOST` to the Colima socket. |

More hooks welcome — see "Authoring a hook" below.

## Hook contract

Hooks are **sourced** (not executed) by `up.sh`. That means:

- `export VAR=value` inside the hook persists into `up.sh`'s following
  `docker` calls. This is how `colima.sh` sets `DOCKER_HOST`.
- `set -e` in the hook affects `up.sh` (which already has `set -euo pipefail`).
- `exit 1` in the hook terminates `up.sh`. Prefer `return 1 2>/dev/null || exit 1`
  so the hook also runs standalone for debugging.

Rules:

1. **Idempotent** — running twice must be safe (check current state first).
2. **Fast-fail** — if something is wrong and can't be auto-fixed, print an
   actionable error to stderr and return non-zero.
3. **No output on happy path beyond one-line confirmation** — keep `up.sh`
   output readable.
4. **Set `DOCKER_HOST` if your runtime uses a non-standard socket** — so the
   parent `up.sh` finds your daemon.

## Authoring a hook

Template:

```bash
#!/bin/bash
# my-hook.sh — one-line summary
#
# Sourced by scripts/up.sh when GATEII_PREUP_HOOK=scripts/hooks/my-hook.sh

GRN='\033[0;32m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'

# Guard: only run where applicable
if [ "$(uname)" != "Linux" ]; then
    echo -e "  ${RED}✗${NC} my-hook.sh is Linux-only" >&2
    return 1 2>/dev/null || exit 1
fi

# Do the thing, idempotently
if already_done; then
    echo -e "  ${GRN}✓${NC} Already set up"
else
    echo -e "  ${DIM}Setting up...${NC}"
    do_the_thing || { echo "failed" >&2; return 1 2>/dev/null || exit 1; }
    echo -e "  ${GRN}✓${NC} Set up"
fi

# Export env that up.sh's docker calls need
# export DOCKER_HOST=unix:///custom/socket
```

Test it standalone:

```bash
bash scripts/hooks/my-hook.sh   # runs as a subprocess — exports won't persist
GATEII_PREUP_HOOK=scripts/hooks/my-hook.sh ./scripts/up.sh   # real integration
```

## Why a hook system instead of hardcoding Colima

Colima is one of several macOS Docker options (Docker Desktop, OrbStack,
Rancher Desktop, colima, podman-machine). Linux has native Docker,
Podman, nerdctl. Windows has Docker Desktop and WSL2 variants. Hardcoding
any one of these would exclude everyone else.

The hook is opt-in, separate from the core script, and documented — so
gateii runs out of the box on plain Docker and each platform only pays for
what it enables.
