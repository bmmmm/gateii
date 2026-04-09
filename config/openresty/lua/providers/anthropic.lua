-- providers/anthropic.lua: Anthropic Claude provider
local cjson = require "cjson.safe"

local _M = {}

_M.upstream_url = "https://api.anthropic.com"

-- Read once at module load time — never changes during worker lifetime
local ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY") or ""

function _M.build_headers(upstream_key, auth_type)
    local headers = {
        ["Content-Type"]      = "application/json",
        ["anthropic-version"] = "2023-06-01",
    }
    -- Preserve original auth format: OAuth Bearer tokens must not be sent as x-api-key
    if auth_type == "bearer" then
        headers["Authorization"] = "Bearer " .. (upstream_key or "")
    else
        headers["x-api-key"] = upstream_key or ANTHROPIC_API_KEY
    end
    return headers
end

-- Returns: input_tokens, output_tokens, stop_reason, cache_creation, cache_read (from SSE body)
function _M.extract_tokens_streaming(body)
    local input_tokens, output_tokens, stop_reason, cache_creation, cache_read = 0, 0, nil, 0, 0
    local data = body:match("event: message_start\r?\ndata: ([^\r\n]+)")
    if data then
        local obj = cjson.decode(data)
        if obj and obj.message and obj.message.usage then
            local u = obj.message.usage
            input_tokens   = u.input_tokens or 0
            cache_creation = u.cache_creation_input_tokens or 0
            cache_read     = u.cache_read_input_tokens or 0
        end
    end
    data = body:match("event: message_delta\r?\ndata: ([^\r\n]+)")
    if data then
        local obj = cjson.decode(data)
        if obj then
            if obj.usage then output_tokens = obj.usage.output_tokens or 0 end
            if obj.delta then stop_reason = obj.delta.stop_reason end
        end
    end
    return input_tokens, output_tokens, stop_reason, cache_creation, cache_read
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
