-- tracking.lua: token usage counters + cache hit/miss stats + latency + errors + stop_reason
local redis = require "resty.redis"

local _M = {}

local function redis_connect()
    local red = redis:new()
    red:set_timeout(500)  -- short timeout, tracking is fire-and-forget
    local ok, err = red:connect("redis", 6379)
    if not ok then return nil, err end
    return red
end

-- Sanitize Redis key components: colons break key parsing in the exporter
local function sanitize(s)
    return (tostring(s or "unknown"):gsub("[:%s]", "_"):sub(1, 64))
end

-- record(user, provider, model, input_tokens, output_tokens, is_cache_hit, opts)
-- opts = { latency_ms=N, status=N, stop_reason="end_turn"|... }
function _M.record(user, provider, model, input_tokens, output_tokens, is_cache_hit, opts)
    user     = sanitize(user)
    provider = sanitize(provider)
    model    = sanitize(model)
    local red, err = redis_connect()
    if not red then
        ngx.log(ngx.WARN, "tracking: redis connect failed: ", err)
        return
    end

    opts = opts or {}
    local usage_key = "usage:" .. user .. ":" .. provider .. ":" .. model

    red:init_pipeline()

    -- Token counts (only on successful upstream responses)
    if input_tokens > 0 then
        red:hincrby(usage_key, "input", input_tokens)
    end
    if output_tokens > 0 then
        red:hincrby(usage_key, "output", output_tokens)
    end

    -- Request count + latency sum (for average latency computation in Grafana)
    red:hincrby(usage_key, "requests", 1)
    if opts.latency_ms then
        red:hincrbyfloat(usage_key, "latency_ms_sum", opts.latency_ms)
    end

    -- Upstream error count (status != 200 and not a cache hit)
    if not is_cache_hit and opts.status and opts.status ~= 200 then
        red:hincrby(usage_key, "errors", 1)
    end

    -- Cache hit/miss global counters
    if is_cache_hit then
        red:incr("cache:hits")
    else
        red:incr("cache:misses")
    end

    red:commit_pipeline()

    -- stop_reason counter (separate key — multiple values per user/model)
    if opts.stop_reason and opts.stop_reason ~= ngx.null and opts.stop_reason ~= "" then
        local stop_key = "stop:" .. user .. ":" .. provider .. ":" .. model .. ":" .. opts.stop_reason
        red:incr(stop_key)
    end

    red:set_keepalive(10000, 100)
end

return _M
