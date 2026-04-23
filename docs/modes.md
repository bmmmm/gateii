# Modes

gateii runs in one of two modes, selected via `PROXY_MODE` in `.env`.

## passthrough — Claude Max plan or own key

No API key stored on the server. gateii forwards whatever the client sends.

```ini
# .env
PROXY_MODE=passthrough
PASSTHROUGH_USER=alice     # shown in Grafana (optional)
```

Client settings (`~/.claude/settings.json`):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:8888"
  }
}
```

`gateii switch local-proxy` writes this for you.

**When to use:** single-user setup, Claude Max plan with OAuth token, or
any case where the client already has its own Anthropic credential.

**What gateii still does in passthrough mode:**

- Token counting, cost estimates, per-model breakdowns
- Stop-reason tracking (`end_turn`, `max_tokens`, `tool_use`, …)
- Dashboard and Prometheus metrics
- Circuit breaker for upstream failures

**What gateii does NOT do in passthrough mode:**

- Rate limiting (there's no server-side key to attach limits to)
- Blocking (same reason — the server never stores the key)

## apikey — shared team key

gateii holds the upstream API key. Users get proxy keys (`sk-proxy-...`)
that are bound to a specific upstream provider + credential.

```ini
# .env
PROXY_MODE=apikey
ANTHROPIC_API_KEY=sk-ant-...
ADMIN_TOKEN=<32-hex-bytes>    # required for admin API in apikey mode
```

Issue a proxy key:

```bash
gateii admin add alice \
    --provider anthropic \
    --upstream-key sk-ant-api03-...
# → sk-proxy-4a7f...
```

Client settings:

```json
{
  "env": {
    "ANTHROPIC_API_KEY": "sk-proxy-4a7f...",
    "ANTHROPIC_BASE_URL": "http://your-server:8888"
  }
}
```

**When to use:** team setup where one Anthropic account covers multiple
users, or when you want per-user blocking, rate limits, and daily quotas.

**Storage:** keys live in `data/keys.json` as structured entries:

```json
{
  "sk-proxy-4a7f...": {
    "user": "alice",
    "provider": "anthropic",
    "upstream_key": "sk-ant-api03-...",
    "created_at": "2026-01-15T10:00:00Z"
  }
}
```

Full schema: [keys.md](keys.md). The older flat format (`{key: "user"}`) is
rejected on startup.

## Bootstrap handshake (apikey mode)

Instead of copy-pasting `sk-proxy-...` keys over SSH or Slack, the admin
issues a one-time code + HMAC secret. The client self-installs over a
challenge → exchange → confirm protocol:

```bash
gateii admin bootstrap create \
    --user alice \
    --provider anthropic \
    --upstream-key sk-ant-api03-...
# → prints a one-time URL + HMAC secret
```

Client runs `scripts/gateii-connect.sh` against that URL. Auto-revokes
if the client never confirms.

Full protocol and security model: [bootstrap.md](bootstrap.md).

## Per-key upstream routing

Each key pins its own `provider` + `upstream_key`. This means:

- Different users can route to different providers (Anthropic direct for
  one, OpenRouter for another).
- Adding a new provider doesn't require migrating existing keys.
- The `x-provider` request header is only a fallback override, not the
  primary routing signal.

See [providers.md](providers.md) for how to add a new provider.
