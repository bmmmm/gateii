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

return _M
