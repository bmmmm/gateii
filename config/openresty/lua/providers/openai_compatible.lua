-- providers/openai_compatible.lua: shared logic for OpenAI-compatible providers
local cjson = require "cjson.safe"
local _M = {}

-- Read once at module load time — never changes during worker lifetime
local OPENAI_API_KEY    = os.getenv("OPENAI_API_KEY") or ""
local OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY") or ""

-- Build upstream headers for OpenAI-compatible APIs.
-- auth_type is accepted but ignored — OpenAI-compatible APIs always use Bearer.
-- In passthrough mode upstream_key is the client's key; in apikey mode falls
-- back to OPENAI_API_KEY / OPENROUTER_API_KEY from the environment.
function _M.build_headers(upstream_key, auth_type)
    local key = upstream_key
             or (OPENAI_API_KEY ~= "" and OPENAI_API_KEY)
             or (OPENROUTER_API_KEY ~= "" and OPENROUTER_API_KEY)
             or ""
    return {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. key,
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
