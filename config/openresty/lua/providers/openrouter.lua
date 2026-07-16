-- providers/openrouter.lua: OpenRouter via Anthropic-compatible endpoint
-- Claude Code sends Anthropic-format requests; OpenRouter's /v1/messages
-- accepts and returns Anthropic format. Auth is Bearer instead of x-api-key.
local anthropic = require "providers.anthropic"

local _M = {}

local OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY") or ""

_M.upstream_url = "https://openrouter.ai/api"

-- The account is unfunded and must only ever use ":free" models (20 req/min,
-- 50 req/day). handler.lua reads this marker and rejects any non-":free" model
-- routed here, so a paid model can never be dispatched (402 / unexpected spend).
_M.free_only = true

-- Free-tier fallback pool. When handler.lua sees provider=openrouter +
-- model ends with ":free", it injects a `models` array into the request so
-- OpenRouter automatically retries the next entry on 429/provider errors.
-- Order = preference. Edit here to add/remove entries.
-- Originally selected from a live probe (2026-04-23) — only models that returned
-- 200 without OpenRouter's "providers may train on inputs" privacy opt-in.
-- Re-validated 2026-07-16 against the live /models list: both gemma entries are
-- still listed; the former third entry (arcee-ai/trinity-large-preview:free) was
-- delisted and removed — a delisted id in the injected `models` array can fail
-- the whole request. Only add ids confirmed reachable without the opt-in.
_M.free_fallback_pool = {
    "google/gemma-4-31b-it:free",
    "google/gemma-4-26b-a4b-it:free",
}

function _M.build_headers(upstream_key, _auth_type)
    local key = (upstream_key and upstream_key ~= "" and upstream_key)
             or (OPENROUTER_API_KEY ~= "" and OPENROUTER_API_KEY)
             or ""
    return {
        ["Content-Type"]      = "application/json",
        ["Authorization"]     = "Bearer " .. key,
        ["anthropic-version"] = "2023-06-01",
    }
end

-- Anthropic-format responses — reuse anthropic.lua parsers verbatim.
_M.extract_tokens           = anthropic.extract_tokens
_M.extract_tokens_streaming = anthropic.extract_tokens_streaming

return _M
