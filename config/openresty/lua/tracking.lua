-- tracking.lua: token usage counters via shared dicts (no Redis)
local _M = {}
local util = require "util"

local counters = ngx.shared.counters
local rl_events = ngx.shared.rl_events

-- TTL for lifetime (per-user/provider/model) counters. Default: 60 days.
-- Override via COUNTER_RETENTION_DAYS in .env.
local COUNTER_TTL = (tonumber(os.getenv("COUNTER_RETENTION_DAYS")) or 60) * 86400


-- Detect once whether this build exposes shared_dict:expire (added in
-- lua-nginx-module 0.10.x — present in every supported OpenResty). When absent
-- we simply don't slide the TTL: counters then expire COUNTER_RETENTION_DAYS
-- after their FIRST write instead of after last activity. That degradation is
-- safe; the previous get-then-set fallback was NOT — it could drop a concurrent
-- worker's incr between the get and the set (lost update).
local _has_expire = type(counters.expire) == "function"
if not _has_expire then
    ngx.log(ngx.WARN, "tracking: shared_dict:expire() unavailable — lifetime ",
            "counter TTLs will not slide on activity")
end

-- bump(key, value, ttl[, slide])
-- incr() only sets init_ttl when the key is CREATED — OpenResty does not refresh
-- the TTL on later incr. For lifetime (per-user/provider/model) counters that
-- means an active key resets to 0 ttl-seconds after its FIRST write. When
-- slide=true we re-arm the TTL on every write so the retention window slides on
-- activity. Daily (date-scoped) counters pass slide=false/nil so their 25h
-- window stays anchored to the day they belong to.
local function bump(key, value, ttl, slide)
    local _, err = counters:incr(key, value, 0, ttl)
    if err then
        ngx.log(ngx.ERR, "tracking: incr failed key=", key, " err=", err,
                " free=", counters:free_space())
        return
    end
    if slide and ttl and _has_expire then
        -- expire() returns nil,"not found" only if the key vanished between
        -- incr and here (eviction) — harmless to ignore. No get-then-set
        -- fallback: it was a lost-update race across workers.
        counters:expire(key, ttl)
    end
end

-- record(user, provider, model, input_tokens, output_tokens, opts)
-- opts = { latency_ms=N, status=N, stop_reason="end_turn"|...,
--          cache_creation=N, cache_read=N }
function _M.record(user, provider, model, input_tokens, output_tokens, opts)
    -- user is pre-sanitized by auth.lua; provider/model may contain unsafe chars
    provider = util.sanitize(provider)
    model    = util.sanitize(model)
    opts = opts or {}

    -- Defense-in-depth: a provider returning nil tokens must not crash the whole
    -- record() (which would drop every counter for this request). Per-provider
    -- coercion stays harmless.
    input_tokens  = tonumber(input_tokens) or 0
    output_tokens = tonumber(output_tokens) or 0

    local prefix = user .. "|" .. provider .. "|" .. model

    -- Token counts (only on successful upstream responses)
    if input_tokens > 0 then
        bump(prefix .. "|input", input_tokens, COUNTER_TTL, true)
    end
    if output_tokens > 0 then
        bump(prefix .. "|output", output_tokens, COUNTER_TTL, true)
    end

    -- Cache token counts
    if opts.cache_creation and opts.cache_creation > 0 then
        bump(prefix .. "|cache_creation", opts.cache_creation, COUNTER_TTL, true)
    end
    if opts.cache_read and opts.cache_read > 0 then
        bump(prefix .. "|cache_read", opts.cache_read, COUNTER_TTL, true)
    end

    -- Request count + latency sum (for average latency computation in Grafana)
    bump(prefix .. "|requests", 1, COUNTER_TTL, true)
    if opts.latency_ms then
        bump(prefix .. "|latency_ms_sum", math.floor(opts.latency_ms + 0.5), COUNTER_TTL, true)
    end

    -- Upstream error count (4xx/5xx — 2xx/3xx are not errors)
    if opts.status and opts.status >= 400 then
        bump(prefix .. "|errors", 1, COUNTER_TTL, true)
    end

    -- Status code bucket: 2xx, 3xx, 4xx, 429 (special bucket for rate limiting), 5xx, other
    if opts.status then
        local status_bucket
        if opts.status == 429 then
            status_bucket = "429"
        elseif opts.status >= 200 and opts.status < 300 then
            status_bucket = "2xx"
        elseif opts.status >= 300 and opts.status < 400 then
            status_bucket = "3xx"
        elseif opts.status >= 400 and opts.status < 500 then
            status_bucket = "4xx"
        elseif opts.status >= 500 and opts.status < 600 then
            status_bucket = "5xx"
        else
            status_bucket = "other"
        end
        bump(prefix .. "|status|" .. status_bucket, 1, COUNTER_TTL, true)
    end

    -- Stop reason counter
    if opts.stop_reason and opts.stop_reason ~= ngx.null and opts.stop_reason ~= "" then
        bump(prefix .. "|stop|" .. util.sanitize(opts.stop_reason), 1, COUNTER_TTL, true)
    end

    -- Daily counters (for limit checks) — with TTL (25h = 90000s). No slide:
    -- the window must stay anchored to the day the counter belongs to.
    local today = util.get_today()
    local day_prefix = "day|" .. user .. "|" .. today
    if input_tokens > 0 then
        bump(day_prefix .. "|input", input_tokens, 90000)
    end
    if output_tokens > 0 then
        bump(day_prefix .. "|output", output_tokens, 90000)
    end
    -- omlx reports real prompt size in cache_creation_input_tokens (input_tokens=0);
    -- include cache tokens so tokens_per_day is enforced correctly for omlx users.
    -- This is also correct for real Anthropic prompt-cache usage.
    local combined = (input_tokens or 0) + (output_tokens or 0)
                     + (opts.cache_creation or 0) + (opts.cache_read or 0)
    if combined > 0 then
        bump(day_prefix .. "|total", combined, 90000)
    end
    -- NOTE: the daily |requests counter is bumped ATOMICALLY at admission in
    -- auth.lua (incr-then-check) — bumping it again here would double-count.
end

-- Per-effort counters (effort = "none" when request has no output_config.effort).
-- Writes: user|provider|model|effort|<value>|{requests,input,output}
function _M.record_effort(user, provider, model, effort, input_tokens, output_tokens)
    provider = util.sanitize(provider)
    model    = util.sanitize(model)
    effort   = util.sanitize(effort)
    -- Defense-in-depth: coerce before the >0 guards so nil tokens can't crash.
    input_tokens  = tonumber(input_tokens) or 0
    output_tokens = tonumber(output_tokens) or 0
    local prefix = user .. "|" .. provider .. "|" .. model .. "|effort|" .. effort
    bump(prefix .. "|requests", 1, COUNTER_TTL, true)
    if input_tokens > 0 then
        bump(prefix .. "|input", input_tokens, COUNTER_TTL, true)
    end
    if output_tokens > 0 then
        bump(prefix .. "|output", output_tokens, COUNTER_TTL, true)
    end
end

-- Per-modality counters (modality = "text" or "vision").
-- Writes: user|provider|model|modality|<value>|{requests,input,output}
function _M.record_modality(user, provider, model, has_vision, input_tokens, output_tokens)
    provider = util.sanitize(provider)
    model    = util.sanitize(model)
    -- Defense-in-depth: coerce before the >0 guards so nil tokens can't crash.
    input_tokens  = tonumber(input_tokens) or 0
    output_tokens = tonumber(output_tokens) or 0
    local modality = has_vision and "vision" or "text"
    local prefix = user .. "|" .. provider .. "|" .. model .. "|modality|" .. modality
    bump(prefix .. "|requests", 1, COUNTER_TTL, true)
    if input_tokens > 0 then
        bump(prefix .. "|input", input_tokens, COUNTER_TTL, true)
    end
    if output_tokens > 0 then
        bump(prefix .. "|output", output_tokens, COUNTER_TTL, true)
    end
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
    -- Sanitize like record() does: a raw "|" in model/limit_type would corrupt
    -- metric label parsing downstream.
    local key = "ratelimit_wait|" .. user .. "|" .. util.sanitize(model) .. "|" .. util.sanitize(limit_type)
    local d = rl_events
    local ok, err = d:set(key, seconds, RL_EVENT_TTL)
    if not ok then
        ngx.log(ngx.ERR, "tracking: set_rate_limit_wait failed key=", key, " err=", tostring(err))
    end
end

function _M.set_rate_limit_tokens_at_hit(user, model, limit_type, tokens)
    -- Sanitize like record() does: a raw "|" in model/limit_type would corrupt
    -- metric label parsing downstream.
    local key = "ratelimit_tokens|" .. user .. "|" .. util.sanitize(model) .. "|" .. util.sanitize(limit_type)
    local d = rl_events
    local ok, err = d:set(key, tokens, RL_EVENT_TTL)
    if not ok then
        ngx.log(ngx.ERR, "tracking: set_rate_limit_tokens_at_hit failed key=", key, " err=", tostring(err))
    end
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
function _M.set_rate_limit_5h_utilization(fraction)
    dict_set("ratelimit_5h_utilization", fraction)
end

function _M.set_rate_limit_7d_utilization(fraction)
    dict_set("ratelimit_7d_utilization", fraction)
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
