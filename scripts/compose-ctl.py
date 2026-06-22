#!/usr/bin/env python3
"""compose-ctl: tiny HTTP control plane for gateii's docker-compose stack.

Runs in its own sidecar container with the docker socket mounted. Only
reachable from inside the gateii Docker network (no host port mapping).
The proxy reverse-proxies /internal/admin/services/* through to here under
ADMIN_TOKEN auth.

Whitelist: only services declared in the compose project (via
`docker compose config --services`) can be controlled. Actions are limited
to start/stop/restart/recreate — no exec, no image manipulation, no shell.

Self-restart of the proxy itself is scheduled async with a small delay so
the calling HTTP request can return before the container dies.
"""
import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

PROJECT = os.environ.get("COMPOSE_PROJECT_NAME", "gateii")
COMPOSE_FILES_ENV = os.environ.get(
    "COMPOSE_FILE", "/workspace/docker-compose.yml:/workspace/docker-compose.override.yml"
)
SELF_RESTART_DELAY_SECONDS = 2
SUBPROCESS_TIMEOUT_SECONDS = 30
ALLOWED_ACTIONS = {"start", "stop", "restart", "recreate"}
PROXY_SERVICE_NAME = os.environ.get("PROXY_SERVICE_NAME", "openresty")

# Build compose CLI prefix once. Skip files that don't exist (e.g. override
# is only present when a plugin like git-tracking is enabled).
COMPOSE_CMD = ["docker", "compose", "-p", PROJECT]
for f in COMPOSE_FILES_ENV.split(":"):
    if f and os.path.exists(f):
        COMPOSE_CMD.extend(["-f", f])


def _run(cmd):
    return subprocess.run(
        cmd, capture_output=True, text=True, timeout=SUBPROCESS_TIMEOUT_SECONDS
    )


# scripts/agent-bench is a Python script and writes to data/agents/. We don't
# wait for it — it can take 5+ minutes — so we spawn detached. Concurrent calls
# return 409 if a bench is already running (cheap check via active.json's task
# field starting with "bench:").
BENCH_SCRIPT = "/workspace/scripts/agent-bench"
ACTIVE_FILE  = "/workspace/data/agents/active.json"
# Same lock path scripts/agent-bench uses. os.mkdir is OS-atomic, so two
# near-simultaneous /run-bench POSTs can't both claim it — closes the TOCTOU
# gap where _bench_in_flight() stays False until a trial writes active.json.
BENCH_LOCK_DIR = "/workspace/data/agents/bench.lock.d"


def _bench_in_flight() -> bool:
    try:
        with open(ACTIVE_FILE) as f:
            d = json.load(f)
        return isinstance(d.get("task"), str) and d["task"].startswith("bench:")
    except Exception:
        return False


def run_bench(force: bool = False):
    if not os.path.exists(BENCH_SCRIPT):
        return 500, {"error": f"bench script not found at {BENCH_SCRIPT}"}
    if _bench_in_flight():
        return 409, {"error": "bench already in progress (see active.json)"}
    # Atomic claim before spawn — agent-bench reclaims and releases this lock in
    # its own finally, so we leave it in place once Popen succeeds (the spawned
    # process owns its lifecycle). We only clean it up if Popen itself fails.
    try:
        os.makedirs(os.path.dirname(BENCH_LOCK_DIR), exist_ok=True)
        os.mkdir(BENCH_LOCK_DIR)
    except FileExistsError:
        return 409, {"error": "bench already in progress (lock held)"}
    except OSError as e:
        return 500, {"error": f"could not acquire bench lock: {e}"}
    args = [BENCH_SCRIPT]
    if force:
        args.append("--force")
    try:
        # Detach: setsid so the child survives our HTTP response cycle, and
        # discard its stdio so we don't pin a pipe buffer.
        subprocess.Popen(
            args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            cwd="/workspace",
        )
    except Exception as e:
        # Spawn failed — release the lock we just claimed so a retry can run.
        try:
            os.rmdir(BENCH_LOCK_DIR)
        except OSError:
            pass
        return 500, {"error": f"spawn failed: {e}"}
    return 202, {"status": "started", "force": force}


# Auto-unload watcher — periodically polls oMLX /v1/models/status and unloads
# any model that has been idle longer than its configured TTL. Per-model TTLs
# live at /workspace/data/agents/idle-config.json:
#   {"models": {"<id>": {"ttl_seconds": 600, "enabled": true}, ...},
#    "default_ttl_seconds": 0}     # 0 = disabled by default (omlx own setting wins)
# Without this we'd need omlx's admin API (separate auth flow) to set the
# built-in idle timeout per model. This watcher is purely Bearer-auth.
import urllib.request, urllib.error  # threading already imported at top

OMLX_URL     = os.environ.get("OMLX_URL",     "http://host.docker.internal:8000")
OMLX_API_KEY = os.environ.get("OMLX_API_KEY", "")
IDLE_CONFIG  = "/workspace/data/agents/idle-config.json"
IDLE_TICK_SECONDS = 60


def _idle_config():
    try:
        with open(IDLE_CONFIG) as f:
            return json.load(f)
    except Exception:
        return {}


def _omlx_get(path: str):
    req = urllib.request.Request(
        OMLX_URL + path, method="GET",
        headers={"Authorization": f"Bearer {OMLX_API_KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, json.loads(r.read().decode())
    except Exception as e:
        return 0, {"error": str(e)}


def _omlx_unload(model_id: str):
    req = urllib.request.Request(
        f"{OMLX_URL}/v1/models/{model_id}/unload", method="POST",
        headers={"Authorization": f"Bearer {OMLX_API_KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status
    except Exception:
        return 0


def _enforce_idle():
    cfg = _idle_config()
    rules = (cfg.get("models") or {})
    default_ttl = int(cfg.get("default_ttl_seconds") or 0)
    if not rules and default_ttl <= 0:
        return  # nothing configured; let omlx's own setting govern

    code, data = _omlx_get("/v1/models/status")
    if code != 200:
        return  # omlx unreachable; try again next tick

    now = time.time()
    for m in (data.get("models") or []):
        if not m.get("loaded"):
            continue
        rule = rules.get(m["id"]) or {}
        ttl = int(rule.get("ttl_seconds") or default_ttl)
        if ttl <= 0 or rule.get("enabled") is False:
            continue
        last = m.get("last_access") or 0
        if last <= 0:
            continue  # never used since loading
        if (now - last) >= ttl:
            print(f"idle-watcher: unload {m['id']} (idle {int(now - last)}s ≥ {ttl}s)", flush=True)
            _omlx_unload(m["id"])


def _idle_watcher_loop():
    while True:
        try:
            _enforce_idle()
        except Exception as e:
            print(f"idle-watcher error: {e}", flush=True)
        time.sleep(IDLE_TICK_SECONDS)


def get_idle_config():
    cfg = _idle_config()
    cfg.setdefault("models", {})
    cfg.setdefault("default_ttl_seconds", 0)
    return 200, cfg


def put_idle_config(body: dict):
    # Validate: models is a dict of {model_id: {ttl_seconds:int, enabled:bool}}
    models = body.get("models") or {}
    if not isinstance(models, dict):
        return 400, {"error": "models must be an object"}
    cleaned = {}
    for mid, rule in models.items():
        if not isinstance(mid, str) or not mid:
            return 400, {"error": "model id must be non-empty string"}
        if not isinstance(rule, dict):
            return 400, {"error": f"rule for {mid} must be an object"}
        ttl = rule.get("ttl_seconds", 0)
        if not isinstance(ttl, int) or ttl < 0 or ttl > 86400:
            return 400, {"error": f"{mid}.ttl_seconds must be int in [0, 86400]"}
        cleaned[mid] = {
            "ttl_seconds": ttl,
            "enabled": bool(rule.get("enabled", True)),
        }
    default_ttl = body.get("default_ttl_seconds", 0)
    if not isinstance(default_ttl, int) or default_ttl < 0 or default_ttl > 86400:
        return 400, {"error": "default_ttl_seconds must be int in [0, 86400]"}
    out = {"models": cleaned, "default_ttl_seconds": default_ttl}
    os.makedirs(os.path.dirname(IDLE_CONFIG), exist_ok=True)
    tmp = IDLE_CONFIG + ".tmp"
    with open(tmp, "w") as f:
        json.dump(out, f, indent=2)
        f.write("\n")
    os.replace(tmp, IDLE_CONFIG)
    return 200, out


def list_services():
    """All containers belonging to this compose project (running OR stopped),
    plus any configured services that have no container yet."""
    out = _run([
        "docker", "ps", "-a", "--format", "{{json .}}",
        "--filter", f"label=com.docker.compose.project={PROJECT}",
    ])
    if out.returncode != 0:
        return {"error": out.stderr.strip()}

    containers = []
    seen = set()
    for line in out.stdout.strip().split("\n"):
        if not line:
            continue
        info = json.loads(line)
        labels = dict(
            p.split("=", 1) for p in info.get("Labels", "").split(",") if "=" in p
        )
        svc = labels.get("com.docker.compose.service", info.get("Names", ""))
        seen.add(svc)
        containers.append({
            "service": svc,
            "container": info.get("Names"),
            "state": info.get("State"),       # running / exited / paused / created
            "status": info.get("Status"),     # "Up 5 minutes (healthy)"
            "image": info.get("Image"),
            "uptime": info.get("RunningFor"),
        })

    # Append configured-but-never-started services (e.g. opted-in plugins
    # whose user just enabled them and hasn't done `up` yet)
    for svc in configured_services():
        if svc not in seen:
            containers.append({
                "service": svc,
                "container": None,
                "state": "not_created",
                "status": "Never started",
                "image": None,
                "uptime": None,
            })

    containers.sort(key=lambda s: s["service"])
    return {"project": PROJECT, "services": containers}


_services_cache = {"value": None, "expires_at": 0.0}
SERVICES_CACHE_TTL_SECONDS = 30


def configured_services():
    """Service names declared in the compose YAMLs — the action whitelist.
    Cached for 30s to avoid forking `docker compose config --services` on
    every poll + every action (it parses YAML, ~100ms per call)."""
    now = time.monotonic()
    if _services_cache["value"] is not None and now < _services_cache["expires_at"]:
        return _services_cache["value"]
    out = _run(COMPOSE_CMD + ["config", "--services"])
    if out.returncode != 0:
        return []
    services = [s.strip() for s in out.stdout.splitlines() if s.strip()]
    _services_cache["value"] = services
    _services_cache["expires_at"] = now + SERVICES_CACHE_TTL_SECONDS
    return services


def do_action(service, action):
    if action not in ALLOWED_ACTIONS:
        return 400, {"error": f"Unknown action: {action}"}
    valid = configured_services()
    if service not in valid:
        return 400, {"error": f"Unknown service: {service}", "configured": valid}

    if action == "recreate":
        cmd = COMPOSE_CMD + ["up", "-d", "--force-recreate", service]
    elif action == "start":
        # `compose start` only works on existing stopped containers; `up -d`
        # also creates one if it doesn't exist yet (e.g. plugin first-enable).
        cmd = COMPOSE_CMD + ["up", "-d", service]
    else:
        cmd = COMPOSE_CMD + [action, service]

    # Self-restart edge case: when the proxy restarts itself, the request
    # holding this code path dies mid-flight. Schedule async + reply 202.
    if service == PROXY_SERVICE_NAME and action in {"restart", "recreate"}:
        def _delayed():
            time.sleep(SELF_RESTART_DELAY_SECONDS)
            # Caller already got 202; the only place a failure surfaces is here,
            # so log the outcome explicitly instead of discarding the result.
            try:
                out = _run(cmd)
                if out.returncode != 0:
                    print(
                        f"self-restart FAILED ({action} {service}): "
                        f"exit={out.returncode} stderr={out.stderr.strip()}",
                        flush=True,
                    )
                else:
                    print(f"self-restart ok ({action} {service})", flush=True)
            except subprocess.TimeoutExpired:
                print(
                    f"self-restart TIMEOUT ({action} {service}) after "
                    f"{SUBPROCESS_TIMEOUT_SECONDS}s",
                    flush=True,
                )
            except Exception as e:
                print(f"self-restart ERROR ({action} {service}): {e}", flush=True)
        threading.Thread(target=_delayed, daemon=True).start()
        return 202, {
            "ok": True, "service": service, "action": action,
            "scheduled_in_seconds": SELF_RESTART_DELAY_SECONDS,
            "note": "proxy is restarting itself — wait a few seconds then refresh",
        }

    try:
        out = _run(cmd)
    except subprocess.TimeoutExpired:
        return 504, {
            "error": f"'{action} {service}' timed out after "
                     f"{SUBPROCESS_TIMEOUT_SECONDS}s — image pull still in progress?",
            "service": service, "action": action,
        }
    except OSError as e:
        return 500, {
            "error": f"could not run docker compose: {e}",
            "service": service, "action": action,
        }
    if out.returncode != 0:
        return 500, {
            "error": out.stderr.strip() or out.stdout.strip(),
            "exit_code": out.returncode,
        }
    return 200, {
        "ok": True, "service": service, "action": action,
        "stdout": out.stdout.strip(),
    }


INTERNAL_TOKEN = os.environ.get("INTERNAL_TOKEN", "")


class Handler(BaseHTTPRequestHandler):
    server_version = "compose-ctl/1.0"

    def _reply(self, code, body):
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except BrokenPipeError:
            # Client (or self-restarting proxy) hung up before we replied.
            pass

    def _auth_ok(self) -> bool:
        """Defense-in-depth: only accept callers carrying X-Internal-Token
        matching env INTERNAL_TOKEN. The proxy injects this header when
        forwarding /internal/admin/services|agents/bench|agents/idle-config.
        Fail closed: with no INTERNAL_TOKEN set we never serve mutating
        endpoints (see DegradedHandler / main()), so this only runs when a
        token is configured. /health is always allowed so probes work
        regardless of auth state.
        """
        return bool(INTERNAL_TOKEN) and \
            self.headers.get("X-Internal-Token", "") == INTERNAL_TOKEN

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/health":
            return self._reply(200, {"ok": True, "project": PROJECT})
        if not self._auth_ok():
            return self._reply(401, {"error": "missing/invalid X-Internal-Token"})
        if path == "/services":
            return self._reply(200, list_services())
        if path == "/idle-config":
            return self._reply(*get_idle_config())
        return self._reply(404, {"error": f"Not found: {path}"})

    def do_POST(self):
        if not self._auth_ok():
            return self._reply(401, {"error": "missing/invalid X-Internal-Token"})
        path = urlparse(self.path).path.rstrip("/")
        # /services/<name>/<action>
        parts = path.split("/")
        if len(parts) == 4 and parts[1] == "services":
            code, body = do_action(parts[2], parts[3])
            return self._reply(code, body)
        # /run-bench — fire scripts/agent-bench in the background. Returns
        # immediately; progress is visible via active.json + log.jsonl, the
        # final report appears in data/agents/bench-report.md when done.
        # Body: {"force": true} to bypass --smart cache; otherwise default.
        if path == "/run-bench":
            length = int(self.headers.get("Content-Length", "0") or "0")
            try:
                req = json.loads(self.rfile.read(length).decode() or "{}")
            except Exception:
                req = {}
            return self._reply(*run_bench(force=bool(req.get("force"))))
        if path == "/idle-config":
            length = int(self.headers.get("Content-Length", "0") or "0")
            try:
                req = json.loads(self.rfile.read(length).decode() or "{}")
            except Exception:
                req = {}
            return self._reply(*put_idle_config(req))
        return self._reply(404, {"error": f"Not found: {self.path}"})

    def log_message(self, fmt, *args):
        # Quiet default per-request stderr noise; failures still raise/print.
        pass


class DegradedHandler(BaseHTTPRequestHandler):
    """Served when INTERNAL_TOKEN is unset: fail closed. Only /health works
    (for container probes); every other path returns 503 so an unauthenticated
    caller can never reach the docker-socket-backed mutating endpoints."""
    server_version = "compose-ctl/1.0"

    def _reply(self, code, body):
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except BrokenPipeError:
            pass

    def _degraded(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/health":
            return self._reply(200, {"ok": True, "project": PROJECT, "degraded": True})
        return self._reply(503, {
            "error": "INTERNAL_TOKEN not configured; control plane disabled",
            "hint": "generate with: openssl rand -hex 32",
        })

    do_GET = _degraded
    do_POST = _degraded

    def log_message(self, fmt, *args):
        pass


def main():
    port = int(os.environ.get("CTL_PORT", "8090"))
    print(
        f"compose-ctl: project={PROJECT} "
        f"compose_cmd={' '.join(COMPOSE_CMD)} port={port}",
        flush=True,
    )
    # Fail closed: without a shared secret the docker-socket-backed mutating
    # endpoints would be reachable by any sibling on the gateii network. Serve
    # a degraded handler (health-only, 503 for everything else) instead of the
    # full Handler so probes still pass but the control plane stays disabled.
    if not INTERNAL_TOKEN:
        print("compose-ctl: ERROR — INTERNAL_TOKEN not set; refusing to serve "
              "mutating endpoints. Generate with: openssl rand -hex 32 "
              "and set INTERNAL_TOKEN in .env. Running degraded (health-only).",
              flush=True)
        HTTPServer(("0.0.0.0", port), DegradedHandler).serve_forever()
        return
    # Idle-unload watcher in a daemon thread; outlives nothing — dies with the
    # main process (sane shutdown via SIGTERM in compose stop).
    threading.Thread(target=_idle_watcher_loop, daemon=True).start()
    print(f"compose-ctl: idle watcher started (tick={IDLE_TICK_SECONDS}s)", flush=True)
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
