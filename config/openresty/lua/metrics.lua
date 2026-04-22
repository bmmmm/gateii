-- metrics.lua: Prometheus exposition format from shared dicts
local cjson = require "cjson.safe"
local counters = ngx.shared.counters
local blocking_dict = ngx.shared.blocking

local STOP_REASON_ALLOWED = { end_turn=true, max_tokens=true, stop_sequence=true, tool_use=true, refusal=true, pause_turn=true }
local _price_cache = {}
local _price_warn_logged = false

-- Load pricing from providers.json (active provider) or legacy pricing.json
local pricing = {
    { pattern = "opus",   input = 5.0,  output = 25.0 },
    { pattern = "sonnet", input = 3.0,  output = 15.0 },
    { pattern = "haiku",  input = 1.0,  output = 5.0  },
}
local cache_write_mult = 1.25
local cache_read_mult = 0.1
local tokens_window_limit  -- set by try_providers_json() via closure

local schema = require "schema"

local function try_providers_json()
    local cfg, cfg_err = schema.load_validated("/etc/nginx/lua/providers.json", schema.validate_providers)
    if cfg_err then
        if not _price_warn_logged then
            ngx.log(ngx.WARN, "metrics: providers.json validation failed — ", cfg_err, " — using fallback")
            _price_warn_logged = true
        end
        return false
    end
    if not cfg then return false end
    local active_id = cfg.active_provider or "anthropic"
    for _, p in ipairs(cfg.providers) do
        if p.id == active_id and p.models then
            pricing = p.models
            cache_write_mult = p.cache_write_multiplier or cache_write_mult
            cache_read_mult = p.cache_read_multiplier or cache_read_mult
            tokens_window_limit = p.tokens_window_limit  -- may be nil
            _price_warn_logged = false  -- reset on successful load
            _price_cache = {}           -- invalidate model price cache
            return true
        end
    end
    return false
end

local pricing_loaded = try_providers_json()
if not pricing_loaded then
    local f = io.open("/etc/nginx/lua/pricing.json", "r")
        or io.open("/usr/local/openresty/nginx/conf/pricing.json", "r")
    if f then
        local data = f:read("*a")
        f:close()
        local cfg = cjson.decode(data)
        if cfg and cfg.models then
            pricing = cfg.models
            cache_write_mult = cfg.cache_write_multiplier or cache_write_mult
            cache_read_mult = cfg.cache_read_multiplier or cache_read_mult
            pricing_loaded = true
        end
    end
end
if not pricing_loaded then
    if not _price_warn_logged then
        ngx.log(ngx.WARN, "metrics: providers.json and pricing.json not found, using hardcoded defaults -- update providers.json")
        _price_warn_logged = true
    end
end

local function model_price(model)
    local m = model:lower()
    local cached = _price_cache[m]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    for _, p in ipairs(pricing) do
        if m:find(p.pattern, 1, true) then
            _price_cache[m] = p
            return p
        end
    end
    _price_cache[m] = false
    return nil
end

ngx.header["Content-Type"] = "text/plain; version=0.0.4; charset=utf-8"

-- Escape label values per Prometheus spec: \ → \\, " → \", newline → \n
local function escape_label(s)
    return s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
end

-- Collect all counter keys and group by user|provider|model
local keys = counters:get_keys(0) or {}
local usage = {}    -- { "user|provider|model" = { input=N, output=N, ... } }
local stops = {}    -- { "user|provider|model|reason" = N }
local statuses = {} -- { "user|provider|model|bucket" = N }
local rl_wait_lines = {}
local rl_tokens_lines = {}
local cb_state = {}       -- { provider = "closed"|"half_open"|"open" }
local cb_failures = {}    -- { provider = N }
local cb_opened_at = {}   -- { provider = unix_ts }
local effort_usage = {}   -- { "user|provider|model|effort" = { input=N, output=N, requests=N } }
local modality_usage = {} -- { "user|provider|model|modality" = { ... } }

for _, key in ipairs(keys) do
    -- Skip daily counters
    if key:sub(1, 4) == "day|" then
        -- skip
    elseif key:sub(1, 15) == "ratelimit_wait|" then
        -- key format: ratelimit_wait|user|model|limit_type
        local rl_user, rl_model, rl_ltype = key:match("^ratelimit_wait|([^|]+)|([^|]+)|(.+)$")
        if rl_user then
            local val = counters:get(key) or 0
            rl_wait_lines[#rl_wait_lines+1] = string.format(
                'gateii_rate_limit_wait_seconds{user="%s",model="%s",limit_type="%s"} %d',
                escape_label(rl_user), escape_label(rl_model), escape_label(rl_ltype), val)
        end
    elseif key:sub(1, 17) == "ratelimit_tokens|" then
        -- key format: ratelimit_tokens|user|model|limit_type
        local rl_user, rl_model, rl_ltype = key:match("^ratelimit_tokens|([^|]+)|([^|]+)|(.+)$")
        if rl_user then
            local val = counters:get(key) or 0
            rl_tokens_lines[#rl_tokens_lines+1] = string.format(
                'gateii_rate_limit_tokens_at_hit{user="%s",model="%s",limit_type="%s"} %d',
                escape_label(rl_user), escape_label(rl_model), escape_label(rl_ltype), val)
        end
    elseif key:sub(1, 3) == "cb|" then
        -- Circuit breaker: cb|<provider>|state|failures|opened_at
        local cb_provider, cb_field = key:match("^cb|([^|]+)|(.+)$")
        if cb_provider and cb_field then
            local val = counters:get(key)
            if cb_field == "state" then
                cb_state[cb_provider] = val
            elseif cb_field == "failures" then
                cb_failures[cb_provider] = tonumber(val) or 0
            elseif cb_field == "opened_at" then
                cb_opened_at[cb_provider] = tonumber(val) or 0
            end
        end
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
                local reason = STOP_REASON_ALLOWED[parts[5]] and parts[5] or "other"
                local stop_key = upm .. "|" .. reason
                stops[stop_key] = (stops[stop_key] or 0) + (counters:get(key) or 0)
            elseif #parts == 5 and parts[4] == "status" then
                -- Status code bucket: user|provider|model|status|<bucket>
                local status_key = upm .. "|" .. parts[5]
                statuses[status_key] = (statuses[status_key] or 0) + (counters:get(key) or 0)
            elseif #parts == 6 and parts[4] == "effort" then
                -- Effort dimension: user|provider|model|effort|<value>|<field>
                local ekey = upm .. "|" .. parts[5]
                if not effort_usage[ekey] then effort_usage[ekey] = {} end
                effort_usage[ekey][parts[6]] = counters:get(key) or 0
            elseif #parts == 6 and parts[4] == "modality" then
                -- Modality dimension: user|provider|model|modality|<text|vision>|<field>
                local mkey = upm .. "|" .. parts[5]
                if not modality_usage[mkey] then modality_usage[mkey] = {} end
                modality_usage[mkey][parts[6]] = counters:get(key) or 0
            end
        end
    end
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

-- Tokens, Requests, Latency, Errors — single pass, collect into per-metric buffers
local tok_lines, req_lines, lat_lines, err_lines = {}, {}, {}, {}
for upm, data in pairs(usage) do
    local user, provider, model = upm:match("^([^|]+)|([^|]+)|(.+)$")
    if user then
    local eu, ep, em = labels_upm(user, provider, model)
    for _, typ in ipairs({"input", "output", "cache_creation", "cache_read"}) do
        local val = data[typ] or 0
        if val > 0 then
            tok_lines[#tok_lines+1] = string.format(
                'gateii_tokens_total{user="%s",provider="%s",model="%s",type="%s"} %d',
                eu, ep, em, typ, val)
        end
    end
    local req = data.requests or 0
    if req > 0 then
        req_lines[#req_lines+1] = string.format(
            'gateii_requests_total{user="%s",provider="%s",model="%s"} %d', eu, ep, em, req)
    end
    local lat = data.latency_ms_sum or 0
    if lat > 0 then
        lat_lines[#lat_lines+1] = string.format(
            'gateii_request_duration_ms_total{user="%s",provider="%s",model="%s"} %.2f', eu, ep, em, lat)
    end
    local errs = data.errors or 0
    if errs > 0 then
        err_lines[#err_lines+1] = string.format(
            'gateii_upstream_errors_total{user="%s",provider="%s",model="%s"} %d', eu, ep, em, errs)
    end
    else
        ngx.log(ngx.WARN, "metrics: unparseable usage key, skipping: ", upm)
    end
end

add("# HELP gateii_tokens_total Token usage by user/provider/model/type")
add("# TYPE gateii_tokens_total counter")
for _, l in ipairs(tok_lines) do add(l) end

add("# HELP gateii_requests_total Total proxied requests by user/provider/model")
add("# TYPE gateii_requests_total counter")
for _, l in ipairs(req_lines) do add(l) end

add("# HELP gateii_request_duration_ms_total Cumulative upstream latency in ms")
add("# TYPE gateii_request_duration_ms_total counter")
for _, l in ipairs(lat_lines) do add(l) end

add("# HELP gateii_upstream_errors_total Upstream non-200 responses")
add("# TYPE gateii_upstream_errors_total counter")
for _, l in ipairs(err_lines) do add(l) end

-- Cost (cache-aware: cache_write = 1.25x input, cache_read = 0.1x input)
add("# HELP gateii_cost_dollars_total Estimated API cost in USD (Anthropic pricing)")
add("# TYPE gateii_cost_dollars_total counter")
for upm, data in pairs(usage) do
    local user, provider, model = upm:match("^([^|]+)|([^|]+)|(.+)$")
    local price = user and model_price(model) or nil
    local eu, ep, em
    if user then eu, ep, em = labels_upm(user, provider, model) end
    if price then
        -- Standard input/output tokens
        for _, typ in ipairs({"input", "output"}) do
            local tokens = data[typ] or 0
            if tokens > 0 then
                local cost = tokens * price[typ] / 1000000
                add(string.format('gateii_cost_dollars_total{user="%s",provider="%s",model="%s",type="%s"} %.6f',
                    eu, ep, em, typ, cost))
            end
        end
        -- Cache write tokens
        local cache_create = data.cache_creation or 0
        if cache_create > 0 then
            local cost = cache_create * (price.input * cache_write_mult) / 1000000
            add(string.format('gateii_cost_dollars_total{user="%s",provider="%s",model="%s",type="%s"} %.6f',
                eu, ep, em, "cache_write", cost))
        end
        -- Cache read tokens
        local cache_rd = data.cache_read or 0
        if cache_rd > 0 then
            local cost = cache_rd * (price.input * cache_read_mult) / 1000000
            add(string.format('gateii_cost_dollars_total{user="%s",provider="%s",model="%s",type="%s"} %.6f',
                eu, ep, em, "cache_read", cost))
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

-- Status code buckets
add("# HELP gateii_upstream_status_code_total Upstream response status codes bucketed by class (2xx,3xx,4xx,429,5xx,other)")
add("# TYPE gateii_upstream_status_code_total counter")
for key, val in pairs(statuses) do
    local user, provider, model, bucket = key:match("^([^|]+)|([^|]+)|([^|]+)|(.+)$")
    if user and val > 0 then
        local eu, ep, em = labels_upm(user, provider, model)
        add(string.format('gateii_upstream_status_code_total{user="%s",provider="%s",model="%s",status_class="%s"} %d',
            eu, ep, em, escape_label(bucket), val))
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

add("# HELP gateii_rate_limit_wait_seconds Seconds to wait after hitting Anthropic rate limit")
add("# TYPE gateii_rate_limit_wait_seconds gauge")
for _, l in ipairs(rl_wait_lines) do add(l) end

add("# HELP gateii_rate_limit_tokens_at_hit Tokens consumed when rate limit was triggered")
add("# TYPE gateii_rate_limit_tokens_at_hit gauge")
for _, l in ipairs(rl_tokens_lines) do add(l) end

-- Rate limit window: remaining tokens, expired tokens, and reset timestamp
local rl_win_remaining = counters:get("ratelimit_remaining")
local rl_win_expired   = counters:get("ratelimit_tokens_expired")
local rl_reset_ts      = counters:get("ratelimit_reset_ts")

add("# HELP gateii_rate_limit_tokens_remaining Tokens remaining in current Anthropic rate limit window")
add("# TYPE gateii_rate_limit_tokens_remaining gauge")
if rl_win_remaining ~= nil then
    add(string.format("gateii_rate_limit_tokens_remaining %d", rl_win_remaining))
end

add("# HELP gateii_rate_limit_tokens_expired Tokens unused when last rate limit window expired")
add("# TYPE gateii_rate_limit_tokens_expired gauge")
if rl_win_expired ~= nil then
    add(string.format("gateii_rate_limit_tokens_expired %d", rl_win_expired))
end

add("# HELP gateii_rate_limit_seconds_until_reset Seconds until current Anthropic rate limit window resets")
add("# TYPE gateii_rate_limit_seconds_until_reset gauge")
if rl_reset_ts ~= nil then
    -- Parse RFC3339 timestamp (e.g. "2024-01-15T10:30:00Z" or "...+00:00")
    local y, mo, d, h, mi, s = rl_reset_ts:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if y then
        mo, d, h, mi, s = tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
        if mo >= 1 and mo <= 12 and d >= 1 and d <= 31 and h <= 23 and mi <= 59 and s <= 60 then
            local mdays = {0,31,59,90,120,151,181,212,243,273,304,334}
            local days_epoch = (tonumber(y) - 1970) * 365
                + math.floor((tonumber(y) - 1969) / 4)
                + (mdays[mo] or 0) + d - 1
            local reset_unix = days_epoch * 86400 + h * 3600 + mi * 60 + s
            local seconds_remaining = math.max(0, reset_unix - ngx.time())
            add(string.format("gateii_rate_limit_seconds_until_reset %d", seconds_remaining))
        else
            ngx.log(ngx.WARN, "metrics: invalid RFC3339 timestamp, skipping: ", rl_reset_ts)
        end
    end
end

add("# HELP gateii_rate_limit_tokens_max Configured max tokens per rate limit window (from providers.json)")
add("# TYPE gateii_rate_limit_tokens_max gauge")
if tokens_window_limit ~= nil then
    add(string.format("gateii_rate_limit_tokens_max %d", tokens_window_limit))
end

-- Utilization fractions from anthropic-ratelimit-unified-* headers
local rl_5h_util = counters:get("ratelimit_5h_utilization")
local rl_7d_util = counters:get("ratelimit_7d_utilization")

add("# HELP gateii_rate_limit_5h_utilization Fraction of 5h token window consumed (0.0-1.0, from unified headers)")
add("# TYPE gateii_rate_limit_5h_utilization gauge")
if rl_5h_util ~= nil then
    add(string.format("gateii_rate_limit_5h_utilization %.4f", rl_5h_util))
end

add("# HELP gateii_rate_limit_7d_utilization Fraction of 7-day token window consumed (0.0-1.0, from unified headers)")
add("# TYPE gateii_rate_limit_7d_utilization gauge")
if rl_7d_util ~= nil then
    add(string.format("gateii_rate_limit_7d_utilization %.4f", rl_7d_util))
end

-- 7d reset countdown
local rl_7d_reset_ts = counters:get("ratelimit_7d_reset_ts")
add("# HELP gateii_rate_limit_7d_seconds_until_reset Seconds until the 7-day token window resets")
add("# TYPE gateii_rate_limit_7d_seconds_until_reset gauge")
if rl_7d_reset_ts ~= nil then
    local y7, mo7, d7, h7, mi7, s7 = rl_7d_reset_ts:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if y7 then
        local y7n, mo7n, d7n = tonumber(y7), tonumber(mo7), tonumber(d7)
        local h7n, mi7n, s7n = tonumber(h7), tonumber(mi7), tonumber(s7)
        -- Same bounds guard as the 5h block above: prevents mdays7[0]/nil crash
        if mo7n >= 1 and mo7n <= 12 and d7n >= 1 and d7n <= 31
           and h7n <= 23 and mi7n <= 59 and s7n <= 60 then
            local mdays7 = {0,31,59,90,120,151,181,212,243,273,304,334}
            local days7 = (y7n - 1970) * 365
                + math.floor((y7n - 1969) / 4)
                + mdays7[mo7n] + d7n - 1
            local reset7_unix = days7 * 86400 + h7n * 3600 + mi7n * 60 + s7n
            add(string.format("gateii_rate_limit_7d_seconds_until_reset %d",
                math.max(0, reset7_unix - ngx.time())))
        else
            ngx.log(ngx.WARN, "metrics: invalid 7d RFC3339 timestamp, skipping: ", rl_7d_reset_ts)
        end
    end
end

-- Fallback capacity fraction (extra tokens available after primary 5h window is exhausted)
local rl_fallback_pct = counters:get("ratelimit_fallback_pct")
add("# HELP gateii_rate_limit_fallback_pct Extra token capacity fraction beyond primary 5h limit (0.0-1.0)")
add("# TYPE gateii_rate_limit_fallback_pct gauge")
if rl_fallback_pct ~= nil then
    add(string.format("gateii_rate_limit_fallback_pct %.4f", rl_fallback_pct))
end

-- Circuit breaker state per provider
local CB_STATE_NUM = { closed = 0, half_open = 1, open = 2 }
add("# HELP gateii_circuit_state Circuit breaker state per provider (0=closed, 1=half_open, 2=open)")
add("# TYPE gateii_circuit_state gauge")
for provider, state in pairs(cb_state) do
    add(string.format('gateii_circuit_state{provider="%s"} %d',
        escape_label(provider), CB_STATE_NUM[state] or 0))
end

add("# HELP gateii_circuit_failures Consecutive upstream failures since last success")
add("# TYPE gateii_circuit_failures gauge")
for provider, n in pairs(cb_failures) do
    add(string.format('gateii_circuit_failures{provider="%s"} %d', escape_label(provider), n))
end

add("# HELP gateii_circuit_open_seconds Seconds since circuit last opened (0 if currently closed)")
add("# TYPE gateii_circuit_open_seconds gauge")
for provider, ts in pairs(cb_opened_at) do
    local seconds = 0
    local st = cb_state[provider]
    if (st == "open" or st == "half_open") and ts > 0 then
        seconds = math.max(0, ngx.time() - ts)
    end
    add(string.format('gateii_circuit_open_seconds{provider="%s"} %d', escape_label(provider), seconds))
end

-- Effort dimension (output_config.effort: none|low|medium|high|xhigh|max)
add("# HELP gateii_requests_by_effort_total Requests grouped by output_config.effort")
add("# TYPE gateii_requests_by_effort_total counter")
for key, data in pairs(effort_usage) do
    local user, provider, model, effort = key:match("^([^|]+)|([^|]+)|([^|]+)|(.+)$")
    if user and (data.requests or 0) > 0 then
        add(string.format('gateii_requests_by_effort_total{user="%s",provider="%s",model="%s",effort="%s"} %d',
            escape_label(user), escape_label(provider), escape_label(model), escape_label(effort), data.requests))
    end
end

add("# HELP gateii_tokens_by_effort_total Tokens grouped by output_config.effort")
add("# TYPE gateii_tokens_by_effort_total counter")
for key, data in pairs(effort_usage) do
    local user, provider, model, effort = key:match("^([^|]+)|([^|]+)|([^|]+)|(.+)$")
    if user then
        for _, typ in ipairs({"input", "output"}) do
            local v = data[typ] or 0
            if v > 0 then
                add(string.format('gateii_tokens_by_effort_total{user="%s",provider="%s",model="%s",effort="%s",type="%s"} %d',
                    escape_label(user), escape_label(provider), escape_label(model), escape_label(effort), typ, v))
            end
        end
    end
end

-- Modality dimension (text|vision — vision = request had at least one image content block)
add("# HELP gateii_requests_by_modality_total Requests grouped by modality (text|vision)")
add("# TYPE gateii_requests_by_modality_total counter")
for key, data in pairs(modality_usage) do
    local user, provider, model, modality = key:match("^([^|]+)|([^|]+)|([^|]+)|(.+)$")
    if user and (data.requests or 0) > 0 then
        add(string.format('gateii_requests_by_modality_total{user="%s",provider="%s",model="%s",modality="%s"} %d',
            escape_label(user), escape_label(provider), escape_label(model), escape_label(modality), data.requests))
    end
end

add("# HELP gateii_tokens_by_modality_total Tokens grouped by modality (text|vision)")
add("# TYPE gateii_tokens_by_modality_total counter")
for key, data in pairs(modality_usage) do
    local user, provider, model, modality = key:match("^([^|]+)|([^|]+)|([^|]+)|(.+)$")
    if user then
        for _, typ in ipairs({"input", "output"}) do
            local v = data[typ] or 0
            if v > 0 then
                add(string.format('gateii_tokens_by_modality_total{user="%s",provider="%s",model="%s",modality="%s",type="%s"} %d',
                    escape_label(user), escape_label(provider), escape_label(model), escape_label(modality), typ, v))
            end
        end
    end
end

-- Admin sessions — count of active HttpOnly sessions in the admin_sessions dict
add("# HELP gateii_admin_sessions_active Active admin HttpOnly session count")
add("# TYPE gateii_admin_sessions_active gauge")
local admin_sessions = ngx.shared.admin_sessions
local admin_session_count = 0
if admin_sessions then
    admin_session_count = #admin_sessions:get_keys(0)
end
add(string.format('gateii_admin_sessions_active %d', admin_session_count))

-- Admin login failures (counter) — incremented on 401 in admin_login.lua
add("# HELP gateii_admin_login_failures_total Admin login attempts rejected with 401")
add("# TYPE gateii_admin_login_failures_total counter")
add(string.format('gateii_admin_login_failures_total %d', counters:get("admin_login_failures") or 0))

-- Model pricing (gauge — tracks price changes over time via Prometheus)
add("# HELP gateii_model_pricing_per_mtok Current Anthropic pricing per 1M tokens (USD)")
add("# TYPE gateii_model_pricing_per_mtok gauge")
for _, p in ipairs(pricing) do
    add(string.format('gateii_model_pricing_per_mtok{model="%s",type="input"} %.2f', p.pattern, p.input))
    add(string.format('gateii_model_pricing_per_mtok{model="%s",type="output"} %.2f', p.pattern, p.output))
    add(string.format('gateii_model_pricing_per_mtok{model="%s",type="cache_write"} %.2f', p.pattern, p.input * cache_write_mult))
    add(string.format('gateii_model_pricing_per_mtok{model="%s",type="cache_read"} %.2f', p.pattern, p.input * cache_read_mult))
end

-- Shared dict health (free space in bytes — alert if approaching 0)
add("# HELP gateii_shared_dict_free_bytes Free bytes remaining in shared dicts")
add("# TYPE gateii_shared_dict_free_bytes gauge")
add(string.format('gateii_shared_dict_free_bytes{dict="counters"} %d', counters:free_space()))
local blocking_free = blocking_dict:free_space()
if blocking_free then
    add(string.format('gateii_shared_dict_free_bytes{dict="blocking"} %d', blocking_free))
end
if admin_sessions then
    add(string.format('gateii_shared_dict_free_bytes{dict="admin_sessions"} %d', admin_sessions:free_space()))
end

ngx.print(table.concat(lines, "\n") .. "\n")
