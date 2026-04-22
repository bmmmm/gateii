# keys.json schema

Source of truth for `apikey`-mode authentication. Each proxy key pins a user
**and** the upstream provider + credential it forwards to. Replaces the older
flat `{key: user-string}` format.

Location: `data/keys.json` — auto-created, gitignored, validated on startup by
`schema.validate_keys`.

---

## Schema

```json
{
  "sk-proxy-4a7f1c...": {
    "user":          "alice",
    "provider":      "anthropic",
    "upstream_key":  "sk-ant-api03-...",
    "created_at":    "2026-04-22T19:05:00Z",
    "bootstrap_code": "btp_..."           // optional — set when issued via bootstrap
  }
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| key (object key) | string | yes | `^sk-proxy-[a-f0-9]{32}$` when issued by gateii; min 8 / max 256 chars for custom keys |
| `user` | string | yes | non-empty, used for metrics labels and blocking |
| `provider` | string | yes | must match an entry in `providers.json` (`^[a-z][a-z0-9_]+$`) |
| `upstream_key` | string | yes | 8–512 chars; the actual credential forwarded upstream |
| `created_at` | string (ISO 8601) | no | set by `addkey` / `bootstrap` |
| `bootstrap_code` | string | no | retains provenance when issued via handshake |

Invalid entries refuse to load: the startup validator logs the reason and the
proxy continues with an empty auth cache (all requests 401). Fix the file and
reload.

---

## Per-key upstream routing

`auth.lua` reads `provider` + `upstream_key` from the matched entry and
attaches them to `ngx.ctx`. `handler.lua` then forwards the request to the
per-key upstream — the `x-provider` request header is only a fallback/override,
no longer the primary routing signal.

Consequence: a single gateii instance serves multiple providers simultaneously.
alice → Anthropic direct, bob → OpenRouter, carol → another Anthropic account
— all on the same `ANTHROPIC_BASE_URL` from the client's point of view.

---

## Creating keys

### Via bootstrap handshake (recommended)

See [bootstrap.md](bootstrap.md). The client runs
`scripts/gateii-connect.sh`; the server writes the structured entry with
`created_at` and `bootstrap_code` set.

### Manually

```bash
./scripts/admin.sh add alice \
    --provider anthropic \
    --upstream-key sk-ant-api03-... \
    [--key sk-proxy-custom-value]
```

The script posts to `/internal/admin/addkey` with a JSON body of
`{key, provider, upstream_key}` and the user as a query parameter.

### Rotate

```bash
./scripts/admin.sh rotate alice
```

Issues a fresh `sk-proxy-...` for `alice`, preserves `provider` +
`upstream_key` from the previous entry, and revokes all older keys for the
same user.

### Revoke

```bash
./scripts/admin.sh revoke sk-proxy-4a7f1c...
```

Removes the entry and clears any cached auth for that key.

---

## Migration from the flat format

Old format (rejected as of this release):

```json
{ "sk-proxy-4a7f...": "alice" }
```

Two options:

1. **Re-issue via bootstrap** — fastest for a fresh deploy; old keys are
   dropped, clients run `gateii-connect` once.
2. **In-place rewrite** — for each existing key, decide which provider +
   upstream credential it should use, then rewrite `data/keys.json`:

```bash
jq 'to_entries | map({key: .key, value: {
      user: .value,
      provider: "anthropic",
      upstream_key: env.ANTHROPIC_API_KEY
    }}) | from_entries' data/keys.json.old > data/keys.json
```

Then reload: `docker exec gateii-proxy openresty -s reload`.

The validator rejects the flat format with a precise error — the proxy will
log the violating entry on startup.

---

## Security notes

- `data/keys.json` is gitignored and written atomically via temp + rename.
- Admin `list` responses mask `upstream_key` as `first6 + *** + last4`, never
  the full value.
- Keys cached in `auth_cache` shared dict (5 min TTL) — a revoked key may
  continue to work for up to 5 min. Reduce TTL in `auth.lua` if faster
  invalidation is required.
- `bootstrap_code` is a provenance marker only; the original `secret` and
  `confirm_token` are never persisted in `keys.json`.
