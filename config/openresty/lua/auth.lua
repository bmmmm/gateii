-- auth.lua: API key validation + rate limiting
local redis   = require "resty.redis"
local limit_req = require "resty.limit.req"

local auth_cache = ngx.shared.auth_cache
local lim_store  = ngx.shared.limit_req

-- Rate limiter: 1 req/s average (= 60/min), burst of 10
local lim, lim_err = limit_req.new("limit_req", 1, 10)
if not lim then
    ngx.log(ngx.ERR, "failed to init rate limiter: ", lim_err)
end

local function redis_connect()
    local red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect("redis", 6379)
    if not ok then return nil, err end
    return red
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

-- 2. Lookup user (L1 → L2)
-- In passthrough mode: skip Redis, forward the client's key directly to upstream
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
    user = auth_cache:get(api_key)
    if not user then
        local red, err = redis_connect()
        if not red then
            ngx.log(ngx.ERR, "Redis connect error: ", err)
            ngx.status = 503
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"error":"Service temporarily unavailable — retry in a few seconds"}')
            return ngx.exit(503)
        end
        local val, rerr = red:hget("keys", api_key)
        red:set_keepalive(10000, 100)
        if rerr or not val or val == ngx.null or val == "" then
            ngx.status = 401
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"error":"Invalid API key"}')
            return ngx.exit(401)
        end
        user = val
        auth_cache:set(api_key, user, 300)
    end
end
ngx.ctx.user = user

-- Structured access log (INFO level — visible at nginx warn threshold only in debug)
ngx.log(ngx.INFO, "auth ok user=", user,
    " method=", ngx.var.request_method,
    " uri=", ngx.var.uri,
    " ip=", ngx.var.remote_addr)

-- 3. Rate limit per user
if lim then
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
