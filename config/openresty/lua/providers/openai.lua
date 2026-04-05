-- providers/openai.lua: OpenAI provider (STUB — ready to implement)
-- TODO: set OPENAI_API_KEY in .env and docker-compose
local cjson = require "cjson.safe"

local _M = {}

_M.upstream_url = "https://api.openai.com"

function _M.build_headers(upstream_key, auth_type)
    return {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Bearer " .. (upstream_key or os.getenv("OPENAI_API_KEY") or ""),
    }
end

function _M.extract_tokens(response_body)
    -- TODO: OpenAI uses response.usage.prompt_tokens / completion_tokens
    if not response_body then return 0, 0 end
    local obj = cjson.decode(response_body)
    if not obj or not obj.usage then return 0, 0 end
    return obj.usage.prompt_tokens or 0, obj.usage.completion_tokens or 0
end

return _M
