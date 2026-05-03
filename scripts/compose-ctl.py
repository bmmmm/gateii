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


def configured_services():
    """Service names declared in the compose YAMLs — the action whitelist."""
    out = _run(COMPOSE_CMD + ["config", "--services"])
    if out.returncode != 0:
        return []
    return [s.strip() for s in out.stdout.splitlines() if s.strip()]


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
            _run(cmd)
        threading.Thread(target=_delayed, daemon=True).start()
        return 202, {
            "ok": True, "service": service, "action": action,
            "scheduled_in_seconds": SELF_RESTART_DELAY_SECONDS,
            "note": "proxy is restarting itself — wait a few seconds then refresh",
        }

    out = _run(cmd)
    if out.returncode != 0:
        return 500, {
            "error": out.stderr.strip() or out.stdout.strip(),
            "exit_code": out.returncode,
        }
    return 200, {
        "ok": True, "service": service, "action": action,
        "stdout": out.stdout.strip(),
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "compose-ctl/1.0"

    def _reply(self, code, body):
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        if path == "/services":
            return self._reply(200, list_services())
        if path == "/health":
            return self._reply(200, {"ok": True, "project": PROJECT})
        return self._reply(404, {"error": f"Not found: {path}"})

    def do_POST(self):
        path = urlparse(self.path).path.rstrip("/")
        # /services/<name>/<action>
        parts = path.split("/")
        if len(parts) == 4 and parts[1] == "services":
            code, body = do_action(parts[2], parts[3])
            return self._reply(code, body)
        return self._reply(404, {"error": f"Not found: {self.path}"})

    def log_message(self, fmt, *args):
        # Quiet default per-request stderr noise; failures still raise/print.
        pass


def main():
    port = int(os.environ.get("CTL_PORT", "8090"))
    print(
        f"compose-ctl: project={PROJECT} "
        f"compose_cmd={' '.join(COMPOSE_CMD)} port={port}",
        flush=True,
    )
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
