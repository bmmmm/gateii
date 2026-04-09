-- tracking.lua: token usage counters via shared dicts (no Redis)
local _M = {}

local counters = ngx.shared.counters

-- Sanitize key components: pipes are the separator
local function sanitize(s)
    return (tostring(s or "unknown"):gsub("[:|%s]", "_"):sub(1, 64))
end

-- record(user, provider, model, input_tokens, output_tokens, opts)
-- opts = { latency_ms=N, status=N, stop_reason="end_turn"|...,
--          cache_creation=N, cache_read=N }
function _M.record(user, provider, model, input_tokens, output_tokens, opts)
    -- user is pre-sanitized by auth.lua; provider/model may contain unsafe chars
    provider = sanitize(provider)
    model    = sanitize(model)
    opts = opts or {}

    local prefix = user .. "|" .. provider .. "|" .. model

    -- Token counts (only on successful upstream responses)
    if input_tokens > 0 then
        counters:incr(prefix .. "|input", input_tokens, 0)
    end
    if output_tokens > 0 then
        counters:incr(prefix .. "|output", output_tokens, 0)
    end

    -- Cache token counts
    if opts.cache_creation and opts.cache_creation > 0 then
        counters:incr(prefix .. "|cache_creation", opts.cache_creation, 0)
    end
    if opts.cache_read and opts.cache_read > 0 then
        counters:incr(prefix .. "|cache_read", opts.cache_read, 0)
    end

    -- Request count + latency sum (for average latency computation in Grafana)
    counters:incr(prefix .. "|requests", 1, 0)
    if opts.latency_ms then
        counters:incr(prefix .. "|latency_ms_sum", math.floor(opts.latency_ms + 0.5), 0)
    end

    -- Upstream error count (status != 200)
    if opts.status and opts.status ~= 200 then
        counters:incr(prefix .. "|errors", 1, 0)
    end

    -- Stop reason counter
    if opts.stop_reason and opts.stop_reason ~= ngx.null and opts.stop_reason ~= "" then
        counters:incr(prefix .. "|stop|" .. sanitize(opts.stop_reason), 1, 0)
    end

    -- Daily counters (for limit checks) — with TTL (25h = 90000s)
    local today = os.date("!%Y-%m-%d")
    local day_prefix = "day|" .. user .. "|" .. today
    if input_tokens > 0 then
        counters:incr(day_prefix .. "|input", input_tokens, 0, 90000)
    end
    if output_tokens > 0 then
        counters:incr(day_prefix .. "|output", output_tokens, 0, 90000)
    end
    counters:incr(day_prefix .. "|requests", 1, 0, 90000)
end

local function dict_set(key, value, ttl)
    local ok, err = counters:set(key, value, ttl)
    if not ok then
        ngx.log(ngx.ERR, "tracking: shared dict write failed key=", key, " err=", tostring(err),
                " free=", counters:free_space())
    end
    return ok
end

-- TTL for rate-limit event keys: 30 days so Prometheus history is preserved
-- but old events eventually evict from the dict
local RL_EVENT_TTL = 86400 * 30

function _M.set_rate_limit_wait(user, model, limit_type, seconds)
    local key = "ratelimit_wait|" .. user .. "|" .. model .. "|" .. limit_type
    dict_set(key, seconds, RL_EVENT_TTL)
end

function _M.set_rate_limit_tokens_at_hit(user, model, limit_type, tokens)
    local key = "ratelimit_tokens|" .. user .. "|" .. model .. "|" .. limit_type
    dict_set(key, tokens, RL_EVENT_TTL)
end

-- Store current remaining tokens for the rate limit window
function _M.set_rate_limit_remaining(remaining)
    dict_set("ratelimit_remaining", remaining)
end

-- Store the reset timestamp string for change detection
function _M.get_rate_limit_reset()
    return counters:get("ratelimit_reset_ts")
end

function _M.set_rate_limit_reset(ts)
    dict_set("ratelimit_reset_ts", ts)
end

-- Record tokens that expired (window reset without hitting limit)
function _M.set_rate_limit_tokens_expired(tokens)
    dict_set("ratelimit_tokens_expired", tokens)
end

-- Store utilization fractions from unified rate limit headers (0.0–1.0)
function _M.set_rate_limit_5h_utilization(util)
    dict_set("ratelimit_5h_utilization", util)
end

function _M.set_rate_limit_7d_utilization(util)
    dict_set("ratelimit_7d_utilization", util)
end

-- 7d window reset RFC3339 timestamp
function _M.set_rate_limit_7d_reset(ts)
    dict_set("ratelimit_7d_reset_ts", ts)
end

-- Fraction of extra capacity available after primary 5h limit is consumed (e.g. 0.5 = 50% fallback)
function _M.set_rate_limit_fallback_pct(pct)
    dict_set("ratelimit_fallback_pct", pct)
end

return _M
