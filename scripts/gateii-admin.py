#!/usr/bin/env python3
"""
gateii-admin — analysis engine for gateii-admin.sh
Runs on nutc, reads Redis directly via docker exec.
"""
import json
import os
import subprocess
import sys
import time


# ── Redis helpers ────────────────────────────────────────────────────

def redis(*args):
    cmd = ["docker", "exec", "gateii-redis", "redis-cli"] + [str(a) for a in args]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.stdout.strip()


def redis_lines(*args):
    return [l for l in redis(*args).splitlines() if l]


def hgetall(key):
    lines = redis_lines("HGETALL", key)
    return dict(zip(lines[0::2], lines[1::2]))


def all_scan(pattern):
    return redis_lines("--scan", "--pattern", pattern)


# ── Snapshot (trend computation) ─────────────────────────────────────

SNAP = "/tmp/gateii-admin-snapshot.json"


def load_snap():
    try:
        with open(SNAP) as f:
            return json.load(f)
    except Exception:
        return {}


def save_snap(data):
    with open(SNAP, "w") as f:
        json.dump(data, f)


# ── Stat collection ───────────────────────────────────────────────────

def collect():
    stats = {"ts": time.time(), "users": {}}
    for key in sorted(all_scan("usage:*")):
        parts = key.split(":", 3)
        if len(parts) != 4:
            continue
        _, user, provider, model = parts
        d = hgetall(key)
        uid = f"{user}|{provider}|{model}"
        stats["users"][uid] = {
            "user": user, "provider": provider, "model": model,
            "requests":    int(d.get("requests", 0)),
            "input":       int(d.get("input", 0)),
            "output":      int(d.get("output", 0)),
            "errors":      int(d.get("errors", 0)),
            "latency_sum": float(d.get("latency_ms_sum", 0)),
        }
    stats["cache_hits"]   = int(redis("GET", "cache:hits") or 0)
    stats["cache_misses"] = int(redis("GET", "cache:misses") or 0)
    stats["stop"] = {}
    for key in all_scan("stop:*"):
        parts = key.split(":", 4)
        if len(parts) != 5:
            continue
        stats["stop"][key] = int(redis("GET", key) or 0)
    return stats


# ── Formatting helpers ────────────────────────────────────────────────

def fmt(n):
    n = int(n)
    if n >= 1_000_000:
        return f"{n/1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n/1_000:.1f}k"
    return str(n)


def pct(a, b):
    return f"{100*a/max(b,1):.1f}%"


# ── Commentary engine ─────────────────────────────────────────────────

def comments_for_user(u, prev_u, elapsed_h):
    tips = []
    reqs = u["requests"]
    errs = u["errors"]
    inp  = u["input"]
    out  = u["output"]
    lat  = u["latency_sum"] / max(reqs, 1)

    if reqs > 0:
        err_pct = 100 * errs / reqs
        if err_pct > 50:
            tips.append(f"!! {err_pct:.0f}% error rate — billing issue or invalid key")
        elif err_pct > 10:
            tips.append(f"!  {err_pct:.0f}% error rate — check upstream responses")

    if lat > 8000:
        tips.append(f"~  Very slow ({lat:.0f}ms avg) — large prompts or Anthropic load")
    elif lat > 3000:
        tips.append(f"~  High latency ({lat:.0f}ms avg)")

    if out > 0 and inp > 0:
        ratio = out / inp
        if ratio > 4:
            tips.append(f"i  High output ratio ({ratio:.1f}x) — verbose responses, consider max_tokens")
        elif ratio < 0.15:
            tips.append(f"i  Very short outputs ({ratio:.1f}x) — prompts may be too long")

    if prev_u and elapsed_h > 0.01:
        delta = reqs - prev_u["requests"]
        if delta > 0:
            tips.append(f"+  +{delta} requests since last check ({delta/elapsed_h:.1f}/h)")

    return tips


# ── status command ────────────────────────────────────────────────────

def cmd_status():
    now  = collect()
    prev = load_snap()
    elapsed_h = (now["ts"] - prev.get("ts", now["ts"])) / 3600

    total_reqs   = sum(u["requests"] for u in now["users"].values())
    total_input  = sum(u["input"]    for u in now["users"].values())
    total_output = sum(u["output"]   for u in now["users"].values())
    total_errs   = sum(u["errors"]   for u in now["users"].values())
    hits   = now["cache_hits"]
    misses = now["cache_misses"]
    hit_rate = 100 * hits / max(hits + misses, 1)

    mt = sum(v for k, v in now["stop"].items() if k.endswith(":max_tokens"))
    et = sum(v for k, v in now["stop"].items() if k.endswith(":end_turn"))

    print("\n" + "=" * 54)
    print("  gateii — status")
    print("=" * 54)
    print(f"  Requests total  : {fmt(total_reqs)}")
    print(f"  Tokens  input   : {fmt(total_input)}")
    print(f"  Tokens  output  : {fmt(total_output)}")
    print(f"  Error rate      : {pct(total_errs, total_reqs)}")
    print(f"  Cache hit rate  : {hit_rate:.1f}%  ({fmt(hits)} hits / {fmt(misses)} misses)")
    print(f"  Active users    : {len(now['users'])}")

    if et + mt > 0:
        trunc = 100 * mt / (et + mt)
        print(f"  Truncated resp  : {trunc:.1f}%  (max_tokens hit)")

    if elapsed_h > 0.02 and prev.get("users"):
        prev_reqs = sum(u["requests"] for u in prev["users"].values())
        delta = total_reqs - prev_reqs
        mins = elapsed_h * 60
        print(f"\n  Since last check ({mins:.0f} min ago): +{delta} new requests")

    print()
    alerts = []
    if hit_rate < 10 and total_reqs > 10:
        alerts.append("i  Cache hit rate low — same requests would be served from cache")
    if total_reqs > 0 and total_errs / total_reqs > 0.5:
        alerts.append("!! >50% errors — check Anthropic billing / API key validity")
    if et + mt > 0 and mt / (et + mt) > 0.2:
        alerts.append("!  >20% of responses hit max_tokens — raise max_tokens in requests")
    if total_reqs == 0:
        alerts.append("i  No requests tracked yet — proxy running but no successful completions")

    for a in alerts:
        print(f"  {a}")
    if not alerts:
        print("  OK — no issues detected")
    print("=" * 54)
    save_snap(now)


# ── users command ─────────────────────────────────────────────────────

def cmd_users():
    now  = collect()
    prev = load_snap()
    elapsed_h = (now["ts"] - prev.get("ts", now["ts"])) / 3600

    key_lines = redis_lines("HGETALL", "keys")
    key_map = {}
    pairs = list(zip(key_lines[0::2], key_lines[1::2]))
    for apikey, uname in pairs:
        key_map.setdefault(uname, []).append(apikey)

    all_users = sorted(set(list(key_map.keys()) + [u["user"] for u in now["users"].values()]))

    print("\n" + "=" * 54)
    print("  gateii — users")
    print("=" * 54)

    for uname in all_users:
        nkeys = len(key_map.get(uname, []))
        key_s = f"{nkeys} key" + ("s" if nkeys != 1 else "")
        print(f"\n  [{uname}]  ({key_s})")

        user_stats = {uid: u for uid, u in now["users"].items() if u["user"] == uname}
        if user_stats:
            for uid, u in sorted(user_stats.items()):
                reqs = u["requests"]
                errs = u["errors"]
                inp  = u["input"]
                out  = u["output"]
                lat  = u["latency_sum"] / max(reqs, 1)
                print(f"    Model   : {u['model']}")
                print(f"    Requests: {fmt(reqs)}  errors: {pct(errs, reqs)}")
                print(f"    Tokens  : {fmt(inp)} in / {fmt(out)} out  (ratio {out/max(inp,1):.2f}x)")
                print(f"    Latency : {lat:.0f}ms avg")

                prev_uid = prev.get("users", {}).get(uid)
                for tip in comments_for_user(u, prev_uid, elapsed_h):
                    print(f"    {tip}")

            user_stops = {k: v for k, v in now["stop"].items() if k.split(":")[1] == uname}
            if user_stops:
                reasons = {}
                for k, v in user_stops.items():
                    r = k.split(":")[-1]
                    reasons[r] = reasons.get(r, 0) + v
                summary = "  ".join(f"{r}: {v}" for r, v in sorted(reasons.items()))
                print(f"    Stops   : {summary}")
        else:
            print(f"    (no usage recorded yet)")

    print("\n" + "=" * 54)
    save_snap(now)


# ── keys command ──────────────────────────────────────────────────────

def cmd_keys():
    key_lines = redis_lines("HGETALL", "keys")
    if not key_lines:
        print("No keys registered.")
        return
    pairs = sorted(zip(key_lines[0::2], key_lines[1::2]), key=lambda x: x[1])
    print(f"\n  {'Key (masked)':<44}  User")
    print("  " + "-" * 56)
    for apikey, uname in pairs:
        masked = apikey[:12] + "..." + apikey[-6:]
        print(f"  {masked:<44}  {uname}")
    print()


# ── dispatch ──────────────────────────────────────────────────────────

COMMANDS = {
    "status": cmd_status,
    "users":  cmd_users,
    "keys":   cmd_keys,
}

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    fn  = COMMANDS.get(cmd)
    if not fn:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)
    fn()
