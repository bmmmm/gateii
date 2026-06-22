-- auth.lua: API key validation + rate limiting (no Redis)
local cjson        = require "cjson.safe"
local limit_req    = require "resty.limit.req"
local proxy_config = require "proxy_config"
local util         = require "util"

local auth_cache    = ngx.shared.auth_cache
local blocking_dict = ngx.shared.blocking
local counters      = ngx.shared.counters

-- Tuning (override via env, see .env.example).
local AUTH_CACHE_NEG_TTL = tonumber(os.getenv("AUTH_CACHE_NEG_TTL")) or 60
local AUTH_CACHE_POS_TTL = tonumber(os.getenv("AUTH_CACHE_POS_TTL")) or 300
local RATE_LIMIT_RPS     = tonumber(os.getenv("RATE_LIMIT_RPS"))    or 1
local RATE_LIMIT_BURST   = tonumber(os.getenv("RATE_LIMIT_BURST"))  or 10
-- Console URL surfaced in 429 error bodies so clients know where to manage their key.
local CONSOLE_URL        = os.getenv("CONSOLE_URL") or "http://localhost:8888/console"

-- Request id: honor a valid incoming X-Request-Id, otherwise use nginx's native
-- request_id (32 hex chars, collision-free). The previous custom generator ran
-- math.randomseed per request with only 16 bits of entropy → same-ms same-worker
-- ids collided and defeated log tracing.
local incoming_rid = ngx.var.http_x_request_id or ""
local rid = (#incoming_rid > 0 and #incoming_rid <= 128 and incoming_rid:match("^[A-Za-z0-9%-]+$"))
            and incoming_rid or ngx.var.request_id
ngx.ctx.request_id = rid
ngx.header["X-Request-Id"] = rid

-- Rate limiter: default 1 req/s average (= 60/min), burst of 10.
-- Override via RATE_LIMIT_RPS / RATE_LIMIT_BURST in .env.
local lim, lim_err = limit_req.new("limit_req", RATE_LIMIT_RPS, RATE_LIMIT_BURST)
if not lim then
    ngx.log(ngx.ERR, "failed to init rate limiter: ", lim_err)
end


-- TTL until next midnight UTC (+ 60s buffer for clock skew)
local function ttl_until_midnight()
    local now = os.time()
    return (86400 - (now % 86400)) + 60
end

-- Daily-limit enforcement counters live in the LRU `counters` dict and can be
-- evicted under memory pressure, silently disabling enforcement. We can't
-- relocate the dict from here (cross-file change), but we can make the silent
-- loss observable: when a user with an active daily limit is being checked and
-- the dict is near-full, log a WARN at most once per minute (rate-limited via a
-- short-TTL flag in the quiet `blocking` dict, so this never spams the log).
local function warn_if_counters_near_full(user)
    local free = counters:free_space()
    -- free_space() reports free bytes in fully-free slab pages; a small value
    -- means the dict is close to forcing LRU eviction of enforcement counters.
    if free and free < 8192 then
        if blocking_dict:add("warn|counters_full", 1, 60) then
            ngx.log(ngx.WARN, "[rid=", rid, "] counters dict near-full (free=", free,
                    " bytes); daily-limit enforcement counters for user ", user,
                    " may be evicted — limits could be silently bypassed")
        end
    end
end

-- Reject request with a JSON error response
local function reject(status, message)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ error = message }))
    return ngx.exit(status)
end

-- 1. Extract API key — accept both Anthropic native (x-api-key) and Bearer format
local api_key = ngx.var.http_x_api_key
if not api_key or api_key == "" then
    local auth_header = ngx.var.http_authorization
    if auth_header then
        api_key = auth_header:match("^[Bb]earer%s+(.+)$")
        if api_key then api_key = api_key:match("^%s*(.-)%s*$") end
    end
end
if not api_key or api_key == "" then
    return reject(401, "Missing API key — send x-api-key or Authorization: Bearer <key>")
end

-- 2. Lookup user
-- In passthrough mode: forward the client's key directly to upstream
local proxy_mode = proxy_config.PROXY_MODE
local user

if proxy_mode == "passthrough" then
    -- Use configured name, else fall back to a generic identifier (never log key fragments)
    user = proxy_config.PASSTHROUGH_USER
    ngx.ctx.auth_type = "passthrough"
    ngx.ctx.upstream_key = api_key
    -- Remember original auth format — OAuth tokens must stay as Bearer, not x-api-key
    if ngx.var.http_x_api_key and ngx.var.http_x_api_key ~= "" then
        ngx.ctx.upstream_auth_type = "x-api-key"
    else
        ngx.ctx.upstream_auth_type = "bearer"
    end
else
    ngx.ctx.auth_type = "apikey"
    -- Apikey mode: check shared dict cache, then keys.json.
    -- keys.json entries are structured: {user, provider, upstream_key}; per-user
    -- upstream routing — each proxy key pins to its own provider + upstream credential.
    local cached = auth_cache:get(api_key)
    if cached == false then
        -- Negative cache hit — known invalid key
        return reject(401, "Invalid API key — check your key or run admin.sh add <user>")
    end
    local entry
    if cached then
        entry = cjson.decode(cached)
    end
    if not entry then
        local keys = proxy_config.load_keys()
        local val = keys[api_key]
        if type(val) ~= "table" or not val.user or not val.provider or not val.upstream_key then
            -- MISS on the throttled snapshot. A freshly provisioned key may not
            -- be in this worker's cache yet (10s no-change throttle). Force one
            -- fresh disk read before negative-caching, so onboarding doesn't hit
            -- a 60s 401 storm.
            keys = proxy_config.load_keys(true)
            val = keys[api_key]
        end
        if type(val) ~= "table" or not val.user or not val.provider or not val.upstream_key then
            auth_cache:set(api_key, false, AUTH_CACHE_NEG_TTL)
            return reject(401, "Invalid API key — check your key or run admin.sh add <user>")
        end
        entry = val
        local encoded = cjson.encode({
            user         = entry.user,
            provider     = entry.provider,
            upstream_key = entry.upstream_key,
        })
        if encoded then auth_cache:set(api_key, encoded, AUTH_CACHE_POS_TTL) end
    end
    user = entry.user
    ngx.ctx.upstream_key       = entry.upstream_key
    ngx.ctx.upstream_provider  = entry.provider
    -- Anthropic always uses x-api-key; Bearer is only for OAuth passthrough.
    -- For provisioned upstream keys we default to the provider's native scheme;
    -- providers.build_headers() handles the actual format.
    ngx.ctx.upstream_auth_type = "x-api-key"
end
-- Sanitize user for safe key construction
user = util.sanitize(user)
ngx.ctx.user = user

-- Structured access log (INFO level)
ngx.log(ngx.INFO, "[rid=", rid, "] auth ok user=", user,
    " method=", ngx.var.request_method,
    " uri=", ngx.var.uri,
    " ip=", ngx.var.remote_addr)

-- 3. Check blocked flag + daily limits via shared dicts
do
    -- 3a. Explicit block check
    local blocked = blocking_dict:get("blocked|" .. user)
    if blocked then
        local ttl = blocking_dict:ttl("blocked|" .. user)
        ngx.header["Retry-After"] = (ttl and ttl > 0) and tostring(math.ceil(ttl)) or "3600"
        return reject(429, "Usage limit reached — contact admin to unblock")
    end

    -- 3b. Daily limit checks
    -- Soft limit: pre-request check reads combined post-response total; cannot pre-enforce unknown future token count
    local limits_raw = blocking_dict:get("limits|" .. user)
    if limits_raw then
        local limits, decode_err = cjson.decode(limits_raw)
        if not limits then
            ngx.log(ngx.WARN, "[rid=", rid, "] failed to decode limits for user ", user, ": ", decode_err)
        else
            -- Use util.get_today() (flips exactly at UTC midnight) so the day
            -- bucket matches tracking.lua's. proxy_config.get_today() lags up to
            -- 60s post-midnight, which could 429 + 24h-block a zero-usage user.
            local today = util.get_today()
            local day_prefix = "day|" .. user .. "|" .. today

            -- Make eviction-driven silent enforcement loss observable.
            warn_if_counters_near_full(user)

            if limits.tokens_per_day then
                -- Soft check: tokens_per_day stays a pre-request read of the
                -- post-response total — the future request's token count is
                -- unknown, so it can't be enforced atomically at admission.
                local used_total = counters:get(day_prefix .. "|total") or 0
                if used_total >= limits.tokens_per_day then
                    local ttl = ttl_until_midnight()
                    blocking_dict:set("blocked|" .. user, "auto:tokens_per_day", ttl)
                    ngx.status = 429
                    ngx.header["Content-Type"] = "application/json"
                    ngx.header["Retry-After"] = tostring(ttl)
                    ngx.say(cjson.encode({
                        error = "Daily token limit reached — resets at midnight UTC",
                        usage = { used = used_total, limit = limits.tokens_per_day },
                        retry_after = ttl,
                        console = CONSOLE_URL
                    }))
                    return ngx.exit(429)
                end
            end

            if limits.requests_per_day then
                -- Atomic incr-then-check at admission: a known +1 per request,
                -- so we can count this request before deciding. Avoids the burst
                -- overshoot of a pre-request read of a post-response counter.
                -- tracking.record() no longer bumps day|...|requests (would
                -- double-count). incr returns nil when the dict is full → treat
                -- as fail-open ("or limits.requests_per_day - 1" keeps it under
                -- the limit so a full dict never wrongly blocks).
                local used_reqs = counters:incr(day_prefix .. "|requests", 1, 0, 90000)
                                  or (limits.requests_per_day - 1)
                if used_reqs > limits.requests_per_day then
                    local ttl = ttl_until_midnight()
                    blocking_dict:set("blocked|" .. user, "auto:requests_per_day", ttl)
                    ngx.status = 429
                    ngx.header["Content-Type"] = "application/json"
                    ngx.header["Retry-After"] = tostring(ttl)
                    ngx.say(cjson.encode({
                        error = "Daily request limit reached — resets at midnight UTC",
                        usage = { used = used_reqs, limit = limits.requests_per_day },
                        retry_after = ttl,
                        console = CONSOLE_URL
                    }))
                    return ngx.exit(429)
                end
            end
        end
    end
end

-- 4. Rate limit per user — apikey mode only (documented invariant).
-- In passthrough every client shares the single PASSTHROUGH_USER bucket, so a
-- shared limiter would penalize unrelated clients; passthrough is intentionally
-- unmetered. Burst 10 covers normal interactive use, sustained rate is 1 req/s.
-- Tune via limit_req.new() if needed.
if lim and proxy_config.PROXY_MODE ~= "passthrough" then
    local delay, err = lim:incoming(user, true)
    if not delay then
        if err == "rejected" then
            ngx.header["Retry-After"] = "60"
            return reject(429, "Rate limit exceeded — max 60 requests/min per key")
        end
        ngx.log(ngx.WARN, "[rid=", rid, "] rate limiter error: ", err)
    elseif delay > 0 then
        ngx.sleep(delay)
    end
end
