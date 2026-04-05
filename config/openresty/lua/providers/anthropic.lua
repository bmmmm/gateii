-- providers/anthropic.lua: Anthropic Claude provider
local cjson = require "cjson.safe"

local _M = {}

_M.upstream_url = "https://api.anthropic.com"

function _M.build_headers(upstream_key, auth_type)
    local headers = {
        ["Content-Type"]      = "application/json",
        ["anthropic-version"] = "2023-06-01",
    }
    -- Preserve original auth format: OAuth Bearer tokens must not be sent as x-api-key
    if auth_type == "bearer" then
        headers["Authorization"] = "Bearer " .. (upstream_key or "")
    else
        headers["x-api-key"] = upstream_key or os.getenv("ANTHROPIC_API_KEY") or ""
    end
    return headers
end

-- Returns: input_tokens, output_tokens, stop_reason, cache_creation_tokens, cache_read_tokens
function _M.extract_tokens(response_body)
    if not response_body then return 0, 0, nil, 0, 0 end
    local obj, err = cjson.decode(response_body)
    if not obj then return 0, 0, nil, 0, 0 end
    local u = obj.usage or {}
    local input  = u.input_tokens or 0
    local output = u.output_tokens or 0
    local cache_create = u.cache_creation_input_tokens or 0
    local cache_read   = u.cache_read_input_tokens or 0
    local stop   = obj.stop_reason  -- "end_turn", "max_tokens", "stop_sequence", "tool_use"
    return input, output, stop, cache_create, cache_read
end

return _M
