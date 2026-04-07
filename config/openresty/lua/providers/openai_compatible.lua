-- providers/openai_compatible.lua: shared logic for OpenAI-compatible providers
local cjson = require "cjson.safe"
local _M = {}

-- Build upstream headers for OpenAI-compatible APIs.
-- auth_type is accepted but ignored — OpenAI-compatible APIs always use Bearer.
function _M.build_headers(upstream_key, auth_type)
    return {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. (upstream_key or ""),
    }
end

-- Extract tokens from a non-streaming OpenAI-compatible response body.
-- Returns: input_tokens, output_tokens, stop_reason, cache_creation, cache_read
function _M.extract_tokens(response_body)
    if not response_body then return 0, 0, nil, 0, 0 end
    local obj = cjson.decode(response_body)
    if not obj or not obj.usage then return 0, 0, nil, 0, 0 end
    local stop = obj.choices and obj.choices[1] and obj.choices[1].finish_reason
    return obj.usage.prompt_tokens or 0, obj.usage.completion_tokens or 0, stop, 0, 0
end

return _M
