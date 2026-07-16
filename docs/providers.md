# Adding a provider

gateii can route to any HTTP API that speaks a supported format. Each
provider lives in `config/openresty/lua/providers/` as a Lua module that
exposes a small interface.

## Built-in providers

Registered in `config/openresty/lua/providers/init.lua` — selectable via a
`keys.json` entry's `provider` field (apikey mode) or the `x-provider`
header (passthrough mode, non-internal providers only):

- **`anthropic`** (`providers/anthropic.lua`) — native Anthropic Messages
  API (`https://api.anthropic.com`). Builds `x-api-key` or `Authorization:
  Bearer` headers depending on the original auth type (OAuth Bearer tokens
  are never downgraded to `x-api-key`); parses both streaming
  (`message_start`/`message_delta` SSE events) and non-streaming `usage`
  for token counts.
- **`openai`** (`providers/openai.lua`) — OpenAI API
  (`https://api.openai.com`). Delegates header building and non-streaming
  token extraction to `openai_compatible.lua`, streaming extraction to
  `openai_format.lua`; sets `stream_options_usage = true` so handler.lua
  injects `stream_options: {include_usage: true}` (OpenAI only returns
  usage in streaming responses when explicitly asked).
- **`openrouter`** (`providers/openrouter.lua`) — OpenRouter via its
  Anthropic-compatible `/v1/messages` endpoint (Bearer auth). **Free-tier
  only** — see [Free-tier restriction](#free-tier-restriction-openrouter)
  below. Reuses `anthropic.lua`'s token extractors since OpenRouter's
  Anthropic-format responses match verbatim.
- **`omlx`** (`providers/omlx.lua`) — local [oMLX](https://github.com/jundot/omlx)
  server (`OMLX_URL`, default `http://host.docker.internal:8000`).
  **Internal-only**: not selectable via the client-supplied `x-provider`
  header, only through a trusted per-user `keys.json` pin — otherwise a
  passthrough client could reach the internal model server directly
  (SSRF / RAM-DoS). Uses Anthropic-format token extraction; oMLX reports
  the real prompt size in `cache_creation_input_tokens` with
  `input_tokens=0`, so gateii sums all three input fields.

Two more modules live in the same directory but are shared logic, not
independently selectable providers:

- **`openai_compatible.lua`** — shared `build_headers` (Bearer, falling
  back through `OPENAI_API_KEY` / `OPENROUTER_API_KEY`) and non-streaming
  `extract_tokens` for any OpenAI-wire-format upstream. Used by
  `openai.lua` and (for header building only) `omlx.lua`.
- **`openai_format.lua`** — shared streaming SSE token parser
  (`extract_tokens_streaming`) for OpenAI-format upstreams. Used by
  `openai.lua`.

Both map OpenAI `finish_reason` values to the Anthropic `stop_reason`
vocabulary (`stop→end_turn`, `length→max_tokens`,
`tool_calls`/`function_call→tool_use`, `content_filter→refusal`) so
`metrics.lua`'s stop-reason whitelist doesn't collapse every OpenAI reason
to `"other"`.

### Free-tier restriction (OpenRouter)

The `openrouter` provider is pinned free-tier-only: `providers/openrouter.lua`
sets `_M.free_only = true`, and `handler.lua` handles any non-`:free` model
routed to it based on the admin config (below): it is either rewritten to the
configured **default** `:free` model, or — if no default is set — refused with
`400 {"error":"This provider is free-tier only — ..."}` before it ever reaches
OpenRouter. This guards an unfunded OpenRouter account against accidentally
dispatching a paid model (402 / unexpected spend).

OpenRouter's free tier is capped at **20 requests/min and 50 requests/day**
per account. To smooth over per-model rate limiting within that quota, gateii
auto-injects a `models` fallback array (capped at 3 entries) whenever a `:free`
request doesn't already specify one — OpenRouter then retries the next pool
entry on a 429 or provider error, transparently to the client.

**Capability routing.** handler.lua classifies each free-tier request from cheap
deterministic signals and routes it to a category-appropriate model:

- category = `x-gateii-task` header (if it names a configured route) > **vision**
  (request carries an image block) > **long_context** (estimated input tokens >
  `long_context_threshold`, default 100k) > **general**.
- the category's ordered `:free` model list (`routes.<category>`) supplies the
  model (first entry) and the OpenRouter `models` fallback array (whole list), so
  a per-model 429 retries the next capability-compatible model. Empty categories
  fall through to the `general` route, then `pool`/`default`.

**Configuring pool + default + routes.** All are managed at runtime, persisted to
`data/openrouter-free.json` `{pool, default, routes, long_context_threshold}`
(validated by `schema.validate_openrouter_free`, read by `openrouter_free.lua`
with a ~10s cache). Edit them in the console's **Free Models** tab
(`/console/free`), which lists the currently-available `:free` models live and
provides pool/default plus a per-category routes editor. When no config file
exists, handler.lua falls back to the provider's hardcoded `_M.free_fallback_pool`
and the reject-with-400 behaviour.

> **Note — free-tier budget is account-wide.** OpenRouter's 20 req/min · 50
> req/day cap (1000/day with ≥10 lifetime credits) applies per unfunded account,
> not per model, so routing to "the next free model" does not extend the daily
> budget. Per-*model* 429s are handled by the `models` fallback array;
> account-budget exhaustion is handled separately (below).

**Budget visibility + exhaustion signalling.** OpenRouter sends no rate-limit
headers on successful responses (verified live), so gateii counts every
forwarded free-tier request itself (current-minute + current-UTC-day windows in
the shared dict — an *estimate*: clients hitting the same account outside
gateii are invisible). 429s carry `X-RateLimit-*` headers — but *both* kinds
do: per-model "high demand" RPM 429s report the model's own cap (e.g.
`X-RateLimit-Limit: 8` on `qwen3-coder:free`, reset in unix ms), so gateii only
treats a 429 as account-budget exhaustion when its `X-RateLimit-Limit` matches
a configured account cap (`minute_limit`/`daily_limit`); anything else fails
open. A matching reset timestamp is captured as the authoritative "exhausted
until" signal. While armed, gateii
answers every `:free` request with a clean
`503 {"error":..., "reset_at":"<RFC3339>", "retry_after_seconds":N}` +
`Retry-After` header instead of burning an upstream request — it never swaps to
a different tier or provider (escalation is a per-task concern for the calling
orchestration, see the routing-boundary note in the repo docs). Counts and the
exhaustion state are exposed as `gateii_openrouter_free_*` Prometheus gauges and
in the console's Free Models tab; the window caps are configurable there
(`minute_limit`/`daily_limit`, display-only — OpenRouter enforces).

## Provider interface

Each provider module must export:

| Field | Type | Purpose |
|-------|------|---------|
| `_M.upstream_url` | string | Base URL, e.g. `"https://api.anthropic.com"` |
| `_M.build_headers(upstream_key, auth_type)` | function | Returns a header table for the upstream request |
| `_M.extract_tokens(body)` | function | Returns `input_tokens, output_tokens, stop_reason` from a non-streaming response body |

Optional:

| Field | Type | Purpose |
|-------|------|---------|
| `_M.extract_tokens_streaming(body)` | function | Parses SSE chunks. Returns `input, output, stop_reason, cache_creation, cache_read`. Without this, streaming token counts are 0. |
| `_M.stream_options_usage` | boolean | If `true`, handler.lua injects `stream_options: {include_usage: true}` into the upstream body. Needed for OpenAI-format providers to return usage in streaming responses. |

## Example

Create `config/openresty/lua/providers/myprovider.lua`:

```lua
local cjson = require "cjson.safe"
local _M = {}

_M.upstream_url = "https://api.example.com"

function _M.build_headers(upstream_key, auth_type)
    return {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. (upstream_key or ""),
    }
end

-- Returns: input_tokens, output_tokens, stop_reason
function _M.extract_tokens(body)
    local obj = cjson.decode(body)
    if not obj or not obj.usage then return 0, 0, nil end
    return obj.usage.input_tokens or 0,
           obj.usage.output_tokens or 0,
           obj.stop_reason
end

return _M
```

Register in `config/openresty/lua/providers/init.lua`:

```lua
providers["myprovider"] = require("providers.myprovider")
```

Add pricing to `config/openresty/lua/providers.json`:

```json
{
  "active_provider": "anthropic",
  "providers": [
    {
      "id": "myprovider",
      "name": "My Provider",
      "url": "https://example.com/pricing",
      "models": [
        { "pattern": "foo",  "name": "Foo Large", "input": 2.0, "output": 8.0 },
        { "pattern": "bar",  "name": "Foo Small", "input": 0.5, "output": 2.0 }
      ]
    }
  ]
}
```

Reload:

```bash
gateii reload
```

Test with a key pinned to the new provider:

```bash
gateii admin add alice \
    --provider myprovider \
    --upstream-key <their-key>
```

## Streaming considerations

Anthropic and OpenAI-format providers encode usage differently in SSE:

- **Anthropic:** usage arrives in `message_start` and `message_delta`
  events. `extract_tokens_streaming` must accumulate across both.
- **OpenAI-format:** usage arrives in a final chunk, but only if
  `stream_options: {include_usage: true}` is in the request — set
  `_M.stream_options_usage = true` and handler.lua injects it for you.

`handler.lua` buffers the full SSE stream in memory before parsing. For
very long responses (> 10 MB) consider streaming token extraction instead,
but this hasn't been needed in practice.

## Per-key routing

Each `data/keys.json` entry pins its own `provider` + `upstream_key`.
The `x-provider` request header can override the key's provider as a
fallback, but per-key pinning is the primary routing signal. See
[keys.md](keys.md) for the full schema.
