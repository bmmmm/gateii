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

-- parse_sse_events(body) → list of {event=string, data=string} tables
-- Implements the SSE spec line-by-line state machine:
-- https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream
local function parse_sse_events(body)
    local events = {}
    local current_event = nil
    local data_lines = {}

    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
        -- Strip trailing \r
        line = line:gsub("\r$", "")

        if line == "" then
            -- Empty line = dispatch event
            if #data_lines > 0 or current_event then
                local data = table.concat(data_lines, "\n")
                -- Remove trailing newline per spec
                if data:sub(-1) == "\n" then data = data:sub(1, -2) end
                events[#events + 1] = {
                    event = current_event or "message",
                    data  = data,
                }
            end
            current_event = nil
            data_lines = {}
        elseif line:sub(1, 1) == ":" then
            -- Comment — ignore
        elseif line:find(":", 1, true) then
            local field, value = line:match("^([^:]+):%s?(.*)")
            if field == "event" then
                current_event = value
            elseif field == "data" then
                data_lines[#data_lines + 1] = value
            end
            -- Ignore id, retry fields
        else
            -- Line with no colon: field name only, value is empty string
            if line == "data" then
                data_lines[#data_lines + 1] = ""
            elseif line == "event" then
                current_event = ""
            end
        end
    end
    return events
end

-- Expose for unit tests
_M.parse_sse_events = parse_sse_events

-- Returns: input_tokens, output_tokens, stop_reason, cache_creation, cache_read (from SSE body)
function _M.extract_tokens_streaming(body)
    local input_tokens, output_tokens, stop_reason, cache_creation, cache_read = 0, 0, nil, 0, 0

    local events = parse_sse_events(body)
    for _, ev in ipairs(events) do
        if ev.event == "message_start" then
            local obj = cjson.decode(ev.data)
            if obj and obj.message and obj.message.usage then
                local u = obj.message.usage
                input_tokens   = u.input_tokens or 0
                cache_creation = u.cache_creation_input_tokens or 0
                cache_read     = u.cache_read_input_tokens or 0
            end
        elseif ev.event == "message_delta" then
            local obj = cjson.decode(ev.data)
            if obj then
                if obj.usage then output_tokens = obj.usage.output_tokens or 0 end
                if obj.delta and type(obj.delta.stop_reason) == "string" then
                    stop_reason = obj.delta.stop_reason
                end
            end
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
    -- cjson.null arrives as userdata, not a string — filter by type
    local stop   = obj.stop_reason
    if type(stop) ~= "string" then stop = nil end
    return input, output, stop, cache_create, cache_read
end

return _M
