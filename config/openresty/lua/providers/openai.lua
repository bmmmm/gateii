-- providers/openai.lua: OpenAI provider (STUB — ready to implement)
-- TODO: set OPENAI_API_KEY in .env and docker-compose
local cjson = require "cjson.safe"
local openai_format = require "providers.openai_format"

local _M = {}

_M.upstream_url = "https://api.openai.com"
_M.stream_options_usage = true
_M.extract_tokens_streaming = openai_format.extract_tokens_streaming

-- Returns: input_tokens, output_tokens, stop_reason, cache_creation, cache_read
function _M.extract_tokens(response_body)
    if not response_body then return 0, 0, nil, 0, 0 end
    local obj = cjson.decode(response_body)
    if not obj or not obj.usage then return 0, 0, nil, 0, 0 end
    return obj.usage.prompt_tokens or 0, obj.usage.completion_tokens or 0,
           obj.choices and obj.choices[1] and obj.choices[1].finish_reason,
           0, 0
end

return _M
