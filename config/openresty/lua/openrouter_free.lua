-- openrouter_free.lua: cached loader for data/openrouter-free.json — the
-- admin-managed OpenRouter free-tier config { pool, default, routes,
-- long_context_threshold, daily_limit, minute_limit } — plus the account-wide
-- free-tier budget bookkeeping (see docs/providers.md § Free-tier restriction).
--   pool    = ordered :free model ids injected as the OpenRouter `models`
--             fallback array (empty → handler falls back to the provider's
--             hardcoded free_fallback_pool).
--   default = a :free model id that a model-less / non-:free request to a
--             free-only provider is rewritten to (empty → reject with 400).
-- handler.lua calls load() on every :free request, so the decode is cached with
-- a short TTL (this config changes rarely; a few seconds of post-save staleness
-- is fine and avoids a per-request file read+decode).
--
-- Budget model: OpenRouter's free tier is capped account-wide (20 req/min,
-- 50 req/day unfunded; 1000/day with ≥10 lifetime credits). Success responses
-- carry NO X-RateLimit-* headers (verified live), so the proxy counts
-- forwarded requests itself (an estimate — clients hitting the same account
-- outside gateii are invisible). 429s carry X-RateLimit-* headers, but BOTH
-- account-cap and per-model "high demand" 429s do (the latter report the
-- model's own RPM cap, e.g. limit=8; reset is unix ms) — handler.lua only
-- arms the "exhausted until" signal when X-RateLimit-Limit matches a
-- configured account cap, and that signal drives its 503 short-circuit. The
-- proxy never swaps tiers on exhaustion — the caller escalates (see
-- CLAUDE.md § Routing boundary).
local cjson = require "cjson.safe"
local util  = require "util"

local _M = {}
local CONFIG_PATH = "/etc/nginx/data/openrouter-free.json"
local TTL = 10
local _cache, _cache_ts = nil, -1

-- Fallback limits for the unfunded tier; override via config daily_limit /
-- minute_limit (e.g. 1000/day once the account holds ≥10 lifetime credits).
local DEFAULT_MINUTE_LIMIT = 20
local DEFAULT_DAILY_LIMIT  = 50

local EXHAUSTED_KEY       = "or_free_exhausted_until"
local EXHAUSTED_LIMIT_KEY = "or_free_exhausted_limit"

function _M.load()
    local now = ngx.time()
    if _cache ~= nil and (now - _cache_ts) < TTL then
        return _cache
    end
    local cfg = {}
    local f = io.open(CONFIG_PATH, "r")
    if f then
        local raw = f:read("*a"); f:close()
        local decoded = raw and cjson.decode(raw)
        if type(decoded) == "table" then cfg = decoded end
    end
    _cache = cfg
    _cache_ts = now
    return cfg
end

-- Effective account limits: configured values with unfunded-tier fallbacks.
-- Returns (minute_limit, daily_limit).
function _M.limits(cfg)
    return tonumber(cfg and cfg.minute_limit) or DEFAULT_MINUTE_LIMIT,
           tonumber(cfg and cfg.daily_limit)  or DEFAULT_DAILY_LIMIT
end

-- Shared-dict keys for the two fixed budget windows: current minute + current
-- UTC day. Fixed (not rolling) windows are a deliberate simplification — the
-- count is an estimate either way.
local function budget_keys(now)
    return "or_free_req|min|" .. math.floor(now / 60),
           "or_free_req|day|" .. util.get_today()
end

-- Count one forwarded free-only request. Called by handler.lua once the
-- upstream actually answered (any status) — locally-failed requests (circuit
-- breaker, connect/send errors) never reached OpenRouter's limiter and are not
-- counted.
function _M.bump_budget()
    local cd = ngx.shared.counters
    local min_key, day_key = budget_keys(ngx.time())
    cd:incr(min_key, 1, 0, 180)    -- outlives its minute for the snapshot read
    cd:incr(day_key, 1, 0, 90000)  -- 25h, anchored to the UTC day (matches day| counters)
end

-- Parse an X-RateLimit-Reset header value into unix seconds, or nil if absent/
-- unusable/in the past. Accepts the three encodings seen in the wild:
-- unix milliseconds (>1e12), unix seconds (~1.7e9), delta seconds (<1e6).
function _M.parse_reset(v, now)
    local n = tonumber(v)
    if not n or n <= 0 then return nil end
    if n > 1e12 then
        n = math.floor(n / 1000)
    elseif n < 1e6 then
        n = now + math.floor(n)
    end
    if n <= now then return nil end
    -- The longest real window is a day — a bogus far-future value must not
    -- lock the proxy out for weeks.
    local cap = now + 26 * 3600
    if n > cap then n = cap end
    return n
end

-- Arm the exhaustion signal until `reset` (unix seconds). `limit` is the
-- X-RateLimit-Limit value at the hit (20 = minute window, 50/1000 = daily),
-- kept for display only.
function _M.arm_exhaustion(reset, limit)
    local cd = ngx.shared.counters
    local ttl = reset - ngx.time()
    if ttl <= 0 then return end
    cd:set(EXHAUSTED_KEY, reset, ttl)
    if tonumber(limit) then cd:set(EXHAUSTED_LIMIT_KEY, tonumber(limit), ttl) end
end

-- Unix seconds until which the free tier is exhausted, or nil. The dict TTL
-- already expires the key at reset; the > now guard covers clock edges.
function _M.get_exhausted_until()
    local v = tonumber(ngx.shared.counters:get(EXHAUSTED_KEY))
    if v and v > ngx.time() then return v end
    return nil
end

-- Build the OpenRouter `models` fallback array for a pinned :free model, or
-- nil when nothing should be injected. Pure — handler.lua owns the request
-- mutation. Injection is skipped when the client opted out via the
-- x-gateii-no-fallback header (presence-based; a pinned model must be served
-- by exactly that model or fail visibly — evals/benchmarks would otherwise
-- silently measure a model mix), when the client supplied its own `models`
-- array, or when the model is not a :free id.
function _M.fallback_models(model, existing_models, pool, no_fallback)
    if no_fallback then return nil end
    if type(pool) ~= "table" or #pool == 0 then return nil end
    if type(existing_models) == "table" then return nil end
    if type(model) ~= "string" or model:sub(-5) ~= ":free" then return nil end
    -- OpenRouter caps the `models` array at 3 entries; truncate silently.
    local MAX_FALLBACK = 3
    local seen = { [model] = true }
    local out = { model }
    for _, m in ipairs(pool) do
        if #out >= MAX_FALLBACK then break end
        if not seen[m] then
            seen[m] = true
            out[#out + 1] = m
        end
    end
    if #out > 1 then return out end
    return nil
end

-- Current budget snapshot for /metrics and the admin API.
-- Returns { minute = {used, limit, remaining}, day = {used, limit, remaining},
--           exhausted_until = unix|nil, exhausted_limit = n|nil }
function _M.budget_snapshot(cfg)
    local cd = ngx.shared.counters
    local now = ngx.time()
    local min_key, day_key = budget_keys(now)
    local minute_limit, daily_limit = _M.limits(cfg)
    local min_used = tonumber(cd:get(min_key)) or 0
    local day_used = tonumber(cd:get(day_key)) or 0
    local exhausted = _M.get_exhausted_until()
    return {
        minute = { used = min_used, limit = minute_limit,
                   remaining = math.max(0, minute_limit - min_used) },
        day    = { used = day_used, limit = daily_limit,
                   remaining = math.max(0, daily_limit - day_used) },
        exhausted_until = exhausted,
        exhausted_limit = exhausted and tonumber(cd:get(EXHAUSTED_LIMIT_KEY)) or nil,
    }
end

return _M
