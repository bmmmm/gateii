import json
import os
import re
from http.server import BaseHTTPRequestHandler, HTTPServer

import redis
from prometheus_client import CONTENT_TYPE_LATEST, REGISTRY, generate_latest
from prometheus_client.core import CounterMetricFamily, GaugeMetricFamily

REDIS_HOST = os.getenv("REDIS_HOST", "redis")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
PORT = int(os.getenv("PORT", "9091"))

rdb = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)

_SAFE_LABEL = re.compile(r"[^a-zA-Z0-9_\-\.]")

# Anthropic public pricing per 1M tokens (USD), matched by model name pattern.
# Order matters: first match wins.
_PRICING = [
    (re.compile(r"opus"),   {"input": 15.0,   "output": 75.0}),
    (re.compile(r"sonnet"), {"input": 3.0,    "output": 15.0}),
    (re.compile(r"haiku"),  {"input": 0.25,   "output": 1.25}),
]


def sanitize_label(value: str, maxlen: int = 64) -> str:
    """Replace characters unsafe in Prometheus label values."""
    return _SAFE_LABEL.sub("_", value)[:maxlen]


def model_price(model: str) -> dict | None:
    """Return $/1M tokens pricing dict for a model, or None if unknown."""
    m = model.lower()
    for pattern, prices in _PRICING:
        if pattern.search(m):
            return prices
    return None


class GateiiCollector:
    def collect(self):
        try:
            yield from self._collect()
        except redis.ConnectionError:
            # Redis down — return empty metrics rather than crashing the scrape
            return
        except redis.TimeoutError:
            return

    def _collect(self):
        # --- Token usage + request stats + cost: scan usage:* ---
        tokens = CounterMetricFamily(
            "gateii_tokens_total",
            "Token usage by user/provider/model/type",
            labels=["user", "provider", "model", "type"],
        )
        requests_c = CounterMetricFamily(
            "gateii_requests_total",
            "Total proxied requests by user/provider/model",
            labels=["user", "provider", "model"],
        )
        latency_sum = CounterMetricFamily(
            "gateii_request_duration_ms_total",
            "Cumulative upstream latency in ms (divide by requests_total for avg)",
            labels=["user", "provider", "model"],
        )
        errors_c = CounterMetricFamily(
            "gateii_upstream_errors_total",
            "Upstream non-200 responses by user/provider/model",
            labels=["user", "provider", "model"],
        )
        cost_c = CounterMetricFamily(
            "gateii_cost_dollars_total",
            "Estimated API cost in USD by user/model/type (Anthropic public pricing)",
            labels=["user", "provider", "model", "type"],
        )

        cursor = 0
        while True:
            cursor, keys = rdb.scan(cursor, match="usage:*", count=100)
            for key in keys:
                # Skip daily usage keys (usage_day:*)
                if key.startswith("usage_day:"):
                    continue
                # Split at most 3 times so model (last segment) may contain colons
                parts = key.split(":", 3)
                if len(parts) != 4:
                    continue
                _, user, provider, model = parts
                labels = [
                    sanitize_label(user),
                    sanitize_label(provider),
                    sanitize_label(model),
                ]
                data = rdb.hgetall(key)
                prices = model_price(model)

                for token_type in ("input", "output"):
                    count = float(data.get(token_type, 0))
                    tokens.add_metric(labels + [token_type], count)
                    if prices:
                        cost = count * prices[token_type] / 1_000_000
                        cost_c.add_metric(labels + [token_type], cost)

                requests_c.add_metric(labels, float(data.get("requests", 0)))
                latency_sum.add_metric(labels, float(data.get("latency_ms_sum", 0)))
                errors_c.add_metric(labels, float(data.get("errors", 0)))
            if cursor == 0:
                break

        yield tokens
        yield requests_c
        yield latency_sum
        yield errors_c
        yield cost_c

        # --- Stop reason counters: scan stop:* ---
        stop_reasons = CounterMetricFamily(
            "gateii_stop_reason_total",
            "Anthropic stop_reason breakdown (end_turn=normal, max_tokens=truncated)",
            labels=["user", "provider", "model", "reason"],
        )
        cursor = 0
        while True:
            cursor, keys = rdb.scan(cursor, match="stop:*", count=100)
            for key in keys:
                # Split at most 4 times: stop / user / provider / model / reason
                parts = key.split(":", 4)
                if len(parts) != 5:
                    continue
                _, user, provider, model, reason = parts
                val = rdb.get(key) or "0"
                stop_reasons.add_metric(
                    [
                        sanitize_label(user),
                        sanitize_label(provider),
                        sanitize_label(model),
                        sanitize_label(reason),
                    ],
                    float(val),
                )
            if cursor == 0:
                break
        yield stop_reasons

        # --- Blocked users: scan blocked:* ---
        blocked_g = GaugeMetricFamily(
            "gateii_user_blocked",
            "1 if user is currently blocked, 0 otherwise",
            labels=["user"],
        )
        cursor = 0
        while True:
            cursor, keys = rdb.scan(cursor, match="blocked:*", count=100)
            for key in keys:
                user = key.split(":", 1)[1]
                blocked_g.add_metric([sanitize_label(user)], 1.0)
            if cursor == 0:
                break
        yield blocked_g


REGISTRY.register(GateiiCollector())


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # silence request logs

    def do_GET(self):
        if self.path == "/metrics":
            output = generate_latest()
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.send_header("Content-Length", str(len(output)))
            self.end_headers()
            self.wfile.write(output)

        elif self.path == "/health":
            try:
                rdb.ping()
                body = b'{"status":"ok"}'
                self.send_response(200)
            except Exception:
                body = b'{"status":"error","detail":"Redis unreachable -- check container logs"}'
                self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        else:
            self.send_response(404)
            self.end_headers()


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"gateii exporter listening on :{PORT}", flush=True)
    server.serve_forever()
