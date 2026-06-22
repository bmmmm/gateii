-- providers/openai_format.lua: shared SSE token parser for OpenAI-format providers
-- Used by openai.lua and openrouter.lua (identical wire format)
local cjson = require "cjson.safe"

local _M = {}

-- Map OpenAI finish_reason → Anthropic stop_reason so metrics.lua's
-- STOP_REASON_ALLOWED whitelist (Anthropic-only) doesn't collapse every
-- OpenAI reason to "other" and lose truncation vs tool-use vs stop.
-- Unknown/nil reasons are left as-is.
local FINISH_REASON_MAP = {
    stop           = "end_turn",
    length         = "max_tokens",
    tool_calls     = "tool_use",
    function_call  = "tool_use",
    content_filter = "refusal",
}

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
                        -- tonumber: coerce strings / drop cjson.null so a bad
                        -- value can't reach tracking.record's `> 0` comparison.
                        input_tokens  = tonumber(obj.usage.prompt_tokens) or input_tokens
                        output_tokens = tonumber(obj.usage.completion_tokens) or output_tokens
                    end
                    -- choices can be cjson.null (not a table) on some upstreams;
                    -- type() check avoids indexing userdata.
                    if type(obj.choices) == "table" and type(obj.choices[1]) == "table" then
                        local fr = obj.choices[1].finish_reason
                        if type(fr) == "string" then stop_reason = FINISH_REASON_MAP[fr] or fr end
                    end
                end
            end
        end
    end
    return input_tokens, output_tokens, stop_reason, 0, 0
end

return _M
