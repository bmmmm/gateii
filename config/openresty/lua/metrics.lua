-- metrics.lua: Prometheus exposition format from shared dicts
local counters = ngx.shared.counters
local blocking_dict = ngx.shared.blocking

-- Anthropic public pricing per 1M tokens (USD)
local pricing = {
    { pattern = "opus",   input = 15.0,   output = 75.0 },
    { pattern = "sonnet", input = 3.0,    output = 15.0 },
    { pattern = "haiku",  input = 0.25,   output = 1.25 },
}

local function model_price(model)
    local m = model:lower()
    for _, p in ipairs(pricing) do
        if m:find(p.pattern, 1, true) then
            return p
        end
    end
    return nil
end

ngx.header["Content-Type"] = "text/plain; version=0.0.4; charset=utf-8"

-- Collect all counter keys and group by user|provider|model
local keys = counters:get_keys(0) or {}
local usage = {}   -- { "user|provider|model" = { input=N, output=N, ... } }
local stops = {}   -- { "user|provider|model|reason" = N }

for _, key in ipairs(keys) do
    -- Skip daily counters
    if key:sub(1, 4) == "day|" then
        -- skip
    else
        -- Parse: user|provider|model|field or user|provider|model|stop|reason
        local parts = {}
        for part in key:gmatch("[^|]+") do
            parts[#parts + 1] = part
        end

        if #parts >= 4 then
            local upm = parts[1] .. "|" .. parts[2] .. "|" .. parts[3]
            if not usage[upm] then
                usage[upm] = {}
            end

            if #parts == 4 then
                -- Regular field: input, output, requests, latency_ms_sum, errors
                usage[upm][parts[4]] = counters:get(key) or 0
            elseif #parts == 5 and parts[4] == "stop" then
                -- Stop reason: user|provider|model|stop|reason
                stops[upm .. "|" .. parts[5]] = counters:get(key) or 0
            end
        end
    end
end

-- Escape label values per Prometheus spec: \ → \\, " → \", newline → \n
local function escape_label(s)
    return s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
end

-- Build output
local lines = {}
local function add(s)
    lines[#lines + 1] = s
end

-- Helper: escaped labels + format string for a given label set
local function labels_upm(user, provider, model)
    return escape_label(user), escape_label(provider), escape_label(model)
end

-- Tokens
add("# HELP gateii_tokens_total Token usage by user/provider/model/type")
add("# TYPE gateii_tokens_total counter")
for upm, data in pairs(usage) do
    local user, provider, model = upm:match("^([^|]+)|([^|]+)|(.+)$")
    local eu, ep, em = labels_upm(user, provider, model)
    for _, typ in ipairs({"input", "output"}) do
        local val = data[typ] or 0
        if val > 0 then
            add(string.format('gateii_tokens_total{user="%s",provider="%s",model="%s",type="%s"} %d',
                eu, ep, em, typ, val))
        end
    end
end

-- Requests
add("# HELP gateii_requests_total Total proxied requests by user/provider/model")
add("# TYPE gateii_requests_total counter")
for upm, data in pairs(usage) do
    local user, provider, model = upm:match("^([^|]+)|([^|]+)|(.+)$")
    local eu, ep, em = labels_upm(user, provider, model)
    local val = data.requests or 0
    if val > 0 then
        add(string.format('gateii_requests_total{user="%s",provider="%s",model="%s"} %d',
            eu, ep, em, val))
    end
end

-- Latency
add("# HELP gateii_request_duration_ms_total Cumulative upstream latency in ms")
add("# TYPE gateii_request_duration_ms_total counter")
for upm, data in pairs(usage) do
    local user, provider, model = upm:match("^([^|]+)|([^|]+)|(.+)$")
    local eu, ep, em = labels_upm(user, provider, model)
    local val = data.latency_ms_sum or 0
    if val > 0 then
        add(string.format('gateii_request_duration_ms_total{user="%s",provider="%s",model="%s"} %.2f',
            eu, ep, em, val))
    end
end

-- Errors
add("# HELP gateii_upstream_errors_total Upstream non-200 responses")
add("# TYPE gateii_upstream_errors_total counter")
for upm, data in pairs(usage) do
    local user, provider, model = upm:match("^([^|]+)|([^|]+)|(.+)$")
    local eu, ep, em = labels_upm(user, provider, model)
    local val = data.errors or 0
    if val > 0 then
        add(string.format('gateii_upstream_errors_total{user="%s",provider="%s",model="%s"} %d',
            eu, ep, em, val))
    end
end

-- Cost
add("# HELP gateii_cost_dollars_total Estimated API cost in USD (Anthropic pricing)")
add("# TYPE gateii_cost_dollars_total counter")
for upm, data in pairs(usage) do
    local user, provider, model = upm:match("^([^|]+)|([^|]+)|(.+)$")
    local eu, ep, em = labels_upm(user, provider, model)
    local price = model_price(model)
    if price then
        for _, typ in ipairs({"input", "output"}) do
            local tokens = data[typ] or 0
            if tokens > 0 then
                local cost = tokens * price[typ] / 1000000
                add(string.format('gateii_cost_dollars_total{user="%s",provider="%s",model="%s",type="%s"} %.6f',
                    eu, ep, em, typ, cost))
            end
        end
    end
end

-- Stop reasons
add("# HELP gateii_stop_reason_total Stop reason breakdown")
add("# TYPE gateii_stop_reason_total counter")
for key, val in pairs(stops) do
    local user, provider, model, reason = key:match("^([^|]+)|([^|]+)|([^|]+)|(.+)$")
    if user and val > 0 then
        add(string.format('gateii_stop_reason_total{user="%s",provider="%s",model="%s",reason="%s"} %d',
            escape_label(user), escape_label(provider), escape_label(model), escape_label(reason), val))
    end
end

-- Blocked users
add("# HELP gateii_user_blocked 1 if user is currently blocked")
add("# TYPE gateii_user_blocked gauge")
local block_keys = blocking_dict:get_keys(0) or {}
for _, key in ipairs(block_keys) do
    if key:sub(1, 8) == "blocked|" then
        local buser = key:sub(9)
        add(string.format('gateii_user_blocked{user="%s"} 1', escape_label(buser)))
    end
end

ngx.print(table.concat(lines, "\n") .. "\n")
