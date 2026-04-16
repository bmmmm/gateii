-- auth.lua: API key validation + rate limiting (no Redis)
local cjson        = require "cjson.safe"
local limit_req    = require "resty.limit.req"
local proxy_config = require "proxy_config"

local auth_cache    = ngx.shared.auth_cache
local blocking_dict = ngx.shared.blocking
local counters      = ngx.shared.counters

-- Rate limiter: 1 req/s average (= 60/min), burst of 10
local lim, lim_err = limit_req.new("limit_req", 1, 10)
if not lim then
    ngx.log(ngx.ERR, "failed to init rate limiter: ", lim_err)
end

-- Sanitize user for key construction — must match tracking.lua's sanitize()
local function sanitize(s)
    return (tostring(s or "unknown"):gsub("[:|%s]", "_"):sub(1, 64))
end

-- TTL until next midnight UTC (+ 60s buffer for clock skew)
local function ttl_until_midnight()
    local now = os.time()
    return (86400 - (now % 86400)) + 60
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
    ngx.ctx.upstream_key = api_key
    -- Remember original auth format — OAuth tokens must stay as Bearer, not x-api-key
    if ngx.var.http_x_api_key and ngx.var.http_x_api_key ~= "" then
        ngx.ctx.upstream_auth_type = "x-api-key"
    else
        ngx.ctx.upstream_auth_type = "bearer"
    end
else
    -- Apikey mode: check shared dict cache, then keys.json
    local cached = auth_cache:get(api_key)
    if cached == false then
        -- Negative cache hit — known invalid key
        return reject(401, "Invalid API key — check your key or run admin.sh add <user>")
    end
    user = cached
    if not user then
        local keys = proxy_config.load_keys()
        local val = keys[api_key]
        if not val or val == "" then
            auth_cache:set(api_key, false, 60)  -- negative cache: 60s
            return reject(401, "Invalid API key — check your key or run admin.sh add <user>")
        end
        user = val
        auth_cache:set(api_key, user, 300)
    end
end
-- Sanitize user for safe key construction (must match tracking.lua)
user = sanitize(user)
ngx.ctx.user = user

-- Structured access log (INFO level)
ngx.log(ngx.INFO, "auth ok user=", user,
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

    -- 3b. Daily limit checks (atomic via incr return value to avoid TOCTOU races)
    local limits_raw = blocking_dict:get("limits|" .. user)
    if limits_raw then
        local limits, decode_err = cjson.decode(limits_raw)
        if not limits then
            ngx.log(ngx.WARN, "failed to decode limits for user ", user, ": ", decode_err)
        else
            local today = proxy_config.get_today()
            local day_prefix = "day|" .. user .. "|" .. today

            if limits.tokens_per_day then
                local used_in  = counters:get(day_prefix .. "|input") or 0
                local used_out = counters:get(day_prefix .. "|output") or 0
                local used_total = used_in + used_out
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
                        console = "http://localhost:8888/console"
                    }))
                    return ngx.exit(429)
                end
            end

            if limits.requests_per_day then
                local used_reqs = counters:get(day_prefix .. "|requests") or 0
                if used_reqs >= limits.requests_per_day then
                    local ttl = ttl_until_midnight()
                    blocking_dict:set("blocked|" .. user, "auto:requests_per_day", ttl)
                    ngx.status = 429
                    ngx.header["Content-Type"] = "application/json"
                    ngx.header["Retry-After"] = tostring(ttl)
                    ngx.say(cjson.encode({
                        error = "Daily request limit reached — resets at midnight UTC",
                        usage = { used = used_reqs, limit = limits.requests_per_day },
                        retry_after = ttl,
                        console = "http://localhost:8888/console"
                    }))
                    return ngx.exit(429)
                end
            end
        end
    end
end

-- 4. Rate limit per user (applies in both modes — defense against runaway clients)
-- In passthrough the PASSTHROUGH_USER is a single bucket; burst 10 covers normal
-- interactive use, sustained rate is 1 req/s. Tune via limit_req.new() if needed.
if lim then
    local delay, err = lim:incoming(user, true)
    if not delay then
        if err == "rejected" then
            ngx.header["Retry-After"] = "60"
            return reject(429, "Rate limit exceeded — max 60 requests/min per key")
        end
        ngx.log(ngx.WARN, "rate limiter error: ", err)
    elseif delay > 0 then
        ngx.sleep(delay)
    end
end
