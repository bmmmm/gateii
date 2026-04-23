# Adding a provider

gateii can route to any HTTP API that speaks a supported format. Each
provider lives in `config/openresty/lua/providers/` as a Lua module that
exposes a small interface.

## Built-in providers

- `anthropic` — Anthropic Messages API (native)
- More to come — see `config/openresty/lua/providers/` for the current
  list.

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
