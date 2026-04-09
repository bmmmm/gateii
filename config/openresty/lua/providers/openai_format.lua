-- providers/openai_format.lua: shared SSE token parser for OpenAI-format providers
-- Used by openai.lua and openrouter.lua (identical wire format)
local cjson = require "cjson.safe"

local _M = {}

-- Returns: input_tokens, output_tokens, stop_reason, cache_creation, cache_read
function _M.extract_tokens_streaming(body)
    local input_tokens, output_tokens, stop_reason = 0, 0, nil
    for line in body:gmatch("data: ([^\r\n]+)") do
        if line ~= "[DONE]" then
            -- Plain-string find is far cheaper than a full JSON decode.
            -- Usage is only in the final chunk; finish_reason in the stop chunk.
            -- Skip decode for the hundreds of content-delta chunks that have neither.
            if line:find('"usage"', 1, true) or line:find('"finish_reason"', 1, true) then
                local obj = cjson.decode(line)
                if obj then
                    if obj.usage then
                        input_tokens  = obj.usage.prompt_tokens or input_tokens
                        output_tokens = obj.usage.completion_tokens or output_tokens
                    end
                    if obj.choices and obj.choices[1] then
                        stop_reason = obj.choices[1].finish_reason or stop_reason
                    end
                end
            end
        end
    end
    return input_tokens, output_tokens, stop_reason, 0, 0
end

return _M
