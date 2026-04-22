-- providers/openrouter.lua: OpenRouter via Anthropic-compatible endpoint
-- Claude Code sends Anthropic-format requests; OpenRouter's /v1/messages
-- accepts and returns Anthropic format. Auth is Bearer instead of x-api-key.
local anthropic = require "providers.anthropic"

local _M = {}

local OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY") or ""

_M.upstream_url = "https://openrouter.ai/api"

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
