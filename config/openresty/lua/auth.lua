-- auth.lua: API key validation + rate limiting (no Redis)
local cjson     = require "cjson.safe"
local limit_req = require "resty.limit.req"

local auth_cache = ngx.shared.auth_cache
local blocking_dict = ngx.shared.blocking
local counters = ngx.shared.counters

-- Rate limiter: 1 req/s average (= 60/min), burst of 10
local lim, lim_err = limit_req.new("limit_req", 1, 10)
if not lim then
    ngx.log(ngx.ERR, "failed to init rate limiter: ", lim_err)
end

-- Sanitize user for key construction — must match tracking.lua's sanitize()
local function sanitize(s)
    return (tostring(s or "unknown"):gsub("[:|%s]", "_"):sub(1, 64))
end

-- Load keys from JSON file (apikey mode)
local function load_keys()
    local f = io.open("/etc/nginx/keys.json", "r")
    if not f then return {} end
    local data = f:read("*a")
    f:close()
    local keys = cjson.decode(data)
    return keys or {}
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
    ngx.status = 401
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Missing API key — send x-api-key or Authorization: Bearer <key>"}')
    return ngx.exit(401)
end

-- 2. Lookup user
-- In passthrough mode: forward the client's key directly to upstream
local proxy_mode = os.getenv("PROXY_MODE") or "apikey"
local user

if proxy_mode == "passthrough" then
    -- Use configured name, else derive stable ID from last 8 chars of key
    user = os.getenv("PASSTHROUGH_USER") or ("user_" .. api_key:sub(-8))
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
        ngx.status = 401
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"error":"Invalid API key — check your key or run admin.sh add <user>"}')
        return ngx.exit(401)
    end
    user = cached
    if not user then
        local keys = load_keys()
        local val = keys[api_key]
        if not val or val == "" then
            auth_cache:set(api_key, false, 60)  -- negative cache: 60s
            ngx.status = 401
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"error":"Invalid API key — check your key or run admin.sh add <user>"}')
            return ngx.exit(401)
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
        ngx.status = 429
        ngx.header["Content-Type"] = "application/json"
        ngx.header["Retry-After"] = (ttl and ttl > 0) and tostring(math.ceil(ttl)) or "3600"
        ngx.say('{"error":"Usage limit reached — contact admin to unblock"}')
        return ngx.exit(429)
    end

    -- 3b. Daily token limit check
    local limits_raw = blocking_dict:get("limits|" .. user)
    if limits_raw then
        local limits = cjson.decode(limits_raw)
        if limits then
            local today = os.date("!%Y-%m-%d")
            local day_prefix = "day|" .. user .. "|" .. today

            if limits.tokens_per_day then
                local used_in  = counters:get(day_prefix .. "|input") or 0
                local used_out = counters:get(day_prefix .. "|output") or 0
                if (used_in + used_out) >= limits.tokens_per_day then
                    -- Auto-block until end of day (UTC)
                    local now = os.time()
                    local midnight = now + (86400 - (now % 86400))
                    local ttl = midnight - now + 60
                    blocking_dict:set("blocked|" .. user, "auto:tokens_per_day", ttl)
                    ngx.status = 429
                    ngx.header["Content-Type"] = "application/json"
                    ngx.header["Retry-After"] = tostring(ttl)
                    ngx.say('{"error":"Daily token limit reached — resets at midnight UTC"}')
                    return ngx.exit(429)
                end
            end

            -- 3c. Daily request limit check
            if limits.requests_per_day then
                local used_reqs = counters:get(day_prefix .. "|requests") or 0
                if used_reqs >= limits.requests_per_day then
                    local now = os.time()
                    local midnight = now + (86400 - (now % 86400))
                    local ttl = midnight - now + 60
                    blocking_dict:set("blocked|" .. user, "auto:requests_per_day", ttl)
                    ngx.status = 429
                    ngx.header["Content-Type"] = "application/json"
                    ngx.header["Retry-After"] = tostring(ttl)
                    ngx.say('{"error":"Daily request limit reached — resets at midnight UTC"}')
                    return ngx.exit(429)
                end
            end
        end
    end
end

-- 4. Rate limit per user (apikey mode only — in passthrough you're limiting yourself)
if proxy_mode ~= "passthrough" and lim then
    local delay, err = lim:incoming(user, true)
    if not delay then
        if err == "rejected" then
            ngx.status = 429
            ngx.header["Content-Type"] = "application/json"
            ngx.header["Retry-After"] = "60"
            ngx.say('{"error":"Rate limit exceeded — max 60 requests/min per key"}')
            return ngx.exit(429)
        end
        ngx.log(ngx.WARN, "rate limiter error: ", err)
    elseif delay > 0 then
        ngx.sleep(delay)
    end
end
