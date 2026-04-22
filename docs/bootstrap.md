# Bootstrap handshake

Self-provisioning flow for proxy keys: the admin hands a client a one-time
code + HMAC secret, the client self-installs an `sk-proxy-...` key over a
four-message HMAC-SHA256 protocol. Replaces copy-pasting keys over SSH/Slack.

```
  admin                     proxy                      client
    |   POST /admin/bootstrap   |                         |
    | ------------------------->|  pending[code]=...      |
    |<- {code, secret, expires} |                         |
    |                           |                         |
    |   hand code+secret over a side channel (1x)  ------>|
    |                           |                         |
    |                           |  POST /bootstrap/challenge  {code}
    |                           |<------------------------|
    |                           |-- {nonce} ------------->|
    |                           |  POST /bootstrap/exchange   {code, nonce, proof}
    |                           |<------------------------|   proof = HMAC(secret, code:nonce)
    |                           |  issues sk-proxy-...    |
    |                           |  writes keys.json       |
    |                           |-- {api_key, confirm_token} -->|
    |                           |                         | installs key locally,
    |                           |                         | verifies /health
    |                           |  POST /bootstrap/confirm    {confirm_token, status, proof}
    |                           |<------------------------|   proof = HMAC(secret, confirm_token:status)
    |                           |  installed → commit     |
    |                           |  failed    → revoke     |
    |                           |-- {status} ------------>|
```

---

## Admin side

### Create a bootstrap

```bash
./scripts/admin.sh bootstrap create \
    --user alice \
    --provider anthropic \
    --upstream-key sk-ant-api03-... \
    [--ttl 600]
```

Output (shown **once**, the secret is not stored in plaintext afterwards):

```
Bootstrap created for alice (anthropic):
  code:    btp_dGVzdC1jb2RlLWV4YW1wbGU
  secret:  1b7c3a...                  # 64 hex chars (32 bytes)
  expires: 2026-04-22T21:00:00Z       (TTL 600s)

Hand these to the client (one-time):
  export GATEII_URL=http://localhost:8888
  export GATEII_BOOTSTRAP_CODE=btp_dGVzdC1jb2RlLWV4YW1wbGU
  export GATEII_BOOTSTRAP_SECRET=1b7c3a...
  bash scripts/gateii-connect.sh
```

### List pending + active

```bash
./scripts/admin.sh bootstrap list
```

Shows pending codes (awaiting `/exchange`) and active sessions (key issued,
awaiting `/confirm`).

### Revoke a pending code

```bash
./scripts/admin.sh bootstrap revoke btp_dGVzdC1jb2RlLWV4YW1wbGU
```

Only removes pending codes. Once the client has called `/exchange`, an
`sk-proxy-...` key exists in `keys.json` — revoke it with `admin.sh revoke`.

---

## Client side

```bash
export GATEII_URL=https://gateii.example.com
export GATEII_BOOTSTRAP_CODE=btp_...
export GATEII_BOOTSTRAP_SECRET=<hex>

bash scripts/gateii-connect.sh           # full install into ~/.claude/settings.json
GATEII_DRY_RUN=1 bash scripts/gateii-connect.sh   # handshake only, print result
```

The script handles the entire challenge → exchange → install → confirm flow,
backs up `~/.claude/settings.json`, writes `ANTHROPIC_BASE_URL` +
`ANTHROPIC_API_KEY`, and calls `confirm` with `status=installed` on success or
`status=failed` (with rollback) on any error.

Requires: `curl`, `jq`, `openssl`.

---

## Protocol

All endpoints are POST, JSON in + JSON out, and are **not** IP-restricted —
the one-time code + HMAC guards them.

### `POST /internal/bootstrap/challenge`

```json
→ { "code": "btp_..." }
← { "nonce": "<hex>", "expires_in": 60 }
```

Verifies the code exists and has not expired; generates a fresh 16-byte nonce
(60 s TTL) stored against the pending entry. A stale nonce forces the client
to request a new challenge.

### `POST /internal/bootstrap/exchange`

```json
→ { "code": "btp_...", "nonce": "<hex>", "proof": "<hex>" }
← { "api_key": "sk-proxy-<32 hex>", "user": "...", "provider": "...",
    "confirm_token": "<hex>", "confirm_ttl": 300 }
```

Verifies `proof == HMAC_SHA256(secret, code ":" nonce)` in constant time. On
success:

1. generates `sk-proxy-<16 random bytes as hex>`
2. writes the structured entry to `keys.json` (atomic temp + rename)
3. opens a confirm session (`confirm_token` → session) with 300 s TTL
4. consumes the pending code

Errors: `401` wrong proof, `400` wrong/expired nonce, `404` unknown code.

### `POST /internal/bootstrap/confirm`

```json
→ { "confirm_token": "<hex>", "status": "installed" | "failed", "proof": "<hex>" }
← { "status": "committed" | "revoked", "api_key": "sk-proxy-..." }
```

Verifies `proof == HMAC_SHA256(secret, confirm_token ":" status)`.

- `installed` → session closed, key stays in `keys.json` → `committed`
- `failed`    → key removed from `keys.json`, session closed → `revoked`

A later attempt with the same `confirm_token` returns `404`.

### Auto-revoke sweep

Every 30 s, worker 0 iterates `bootstrap_sessions` and revokes sessions whose
`expires_at` is past. A client that crashes between `exchange` and `confirm`
loses its key automatically within ~5 min.

---

## Security

| Attack | Mitigation |
|---|---|
| Replay of `/challenge` body | Nonce is fresh per request (60 s TTL) |
| Replay of `/exchange` body | `/exchange` consumes the pending code — a replayed call hits `404` |
| Offline brute-force of HMAC | 32-byte (256-bit) secret from `resty.random.bytes(..., true)` |
| Timing attack on proof compare | Constant-time byte-wise XOR accumulator (`bit.bor(..., bxor(...))`) |
| Stolen key that was never confirmed | Auto-revoke after 5 min; client can also explicitly confirm `failed` |
| Man-in-the-middle | TLS (the endpoints are public-reachable but HMAC-authenticated) |
| Code harvesting from admin logs | Code + secret shown **once** on creation; admin API `list` returns code only, never the secret |

The secret never leaves `bootstrap_pending` / `bootstrap_sessions` in shared
memory. Admin `list` and `revoke` do not disclose it.

---

## Admin endpoints

| Method | Path | Body | Purpose |
|---|---|---|---|
| `POST` | `/internal/admin/bootstrap` | `{user, provider, upstream_key, ttl?}` | create |
| `GET`  | `/internal/admin/bootstrap` | — | list pending + sessions |
| `DELETE` | `/internal/admin/bootstrap/<code>` | — | revoke pending |

All require admin auth (cookie or `X-Admin-Token` — see
[admin-api.md](admin-api.md)).

---

## Related

- Client script: [`scripts/gateii-connect.sh`](../scripts/gateii-connect.sh)
- Server impl: [`config/openresty/lua/bootstrap.lua`](../config/openresty/lua/bootstrap.lua)
- Tests: [`spec/bootstrap_spec.lua`](../spec/bootstrap_spec.lua), plus the
  full roundtrip in `scripts/smoke-test.sh` when `ADMIN_TOKEN` is set.
