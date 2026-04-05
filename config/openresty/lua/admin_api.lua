-- admin_api.lua: internal admin endpoints for blocking/unblocking
local cjson = require "cjson.safe"
local blocking_dict = ngx.shared.blocking
local counters = ngx.shared.counters

local method = ngx.req.get_method()
local uri = ngx.var.uri

ngx.header["Content-Type"] = "application/json"

-- Sanitize user for key construction
local function sanitize(s)
    return (tostring(s or ""):gsub("[:|%s]", "_"):sub(1, 64))
end

-- POST /internal/admin/block?user=X&ttl=86400
if uri == "/internal/admin/block" and method == "POST" then
    local args = ngx.req.get_uri_args()
    local user = sanitize(args.user or "")
    if user == "" then
        ngx.status = 400
        ngx.say('{"error":"Missing user parameter"}')
        return
    end
    local ttl = tonumber(args.ttl) or 86400
    blocking_dict:set("blocked|" .. user, "manual", ttl)
    ngx.say(cjson.encode({ok = true, user = user, ttl = ttl}))
    return
end

-- POST /internal/admin/unblock?user=X
if uri == "/internal/admin/unblock" and method == "POST" then
    local args = ngx.req.get_uri_args()
    local user = sanitize(args.user or "")
    if user == "" then
        ngx.status = 400
        ngx.say('{"error":"Missing user parameter"}')
        return
    end
    blocking_dict:delete("blocked|" .. user)
    ngx.say(cjson.encode({ok = true, user = user}))
    return
end

-- POST /internal/admin/limit?user=X  body: {"tokens_per_day":N,"requests_per_day":N}
if uri == "/internal/admin/limit" and method == "POST" then
    ngx.req.read_body()
    local args = ngx.req.get_uri_args()
    local user = sanitize(args.user or "")
    if user == "" then
        ngx.status = 400
        ngx.say('{"error":"Missing user parameter"}')
        return
    end
    local body = ngx.req.get_body_data()
    if not body then
        ngx.status = 400
        ngx.say('{"error":"Missing JSON body with limit fields"}')
        return
    end
    local limits = cjson.decode(body)
    if not limits then
        ngx.status = 400
        ngx.say('{"error":"Invalid JSON body"}')
        return
    end
    blocking_dict:set("limits|" .. user, cjson.encode(limits))
    ngx.say(cjson.encode({ok = true, user = user}))
    return
end

-- GET /internal/admin/status
if uri == "/internal/admin/status" and method == "GET" then
    local blocked = {}
    local block_keys = blocking_dict:get_keys(0)
    for _, key in ipairs(block_keys) do
        if key:sub(1, 8) == "blocked|" then
            local buser = key:sub(9)
            local ttl = blocking_dict:ttl(key)
            blocked[#blocked + 1] = { user = buser, ttl = math.ceil(ttl or 0) }
        end
    end
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({ blocked = blocked }))
    return
end

-- GET /internal/admin/usage?user=X
if uri == "/internal/admin/usage" and method == "GET" then
    local args = ngx.req.get_uri_args()
    local user = sanitize(args.user or "")
    if user == "" then
        ngx.status = 400
        ngx.say('{"error":"Missing user parameter"}')
        return
    end
    local today = os.date("!%Y-%m-%d")
    local day_prefix = "day|" .. user .. "|" .. today
    local result = {
        user = user,
        today = today,
        daily_input = counters:get(day_prefix .. "|input") or 0,
        daily_output = counters:get(day_prefix .. "|output") or 0,
        daily_requests = counters:get(day_prefix .. "|requests") or 0,
    }
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(result))
    return
end

-- GET /internal/admin/keys — list all proxy keys (masked)
if uri == "/internal/admin/keys" and method == "GET" then
    local keys_data = {}
    local count = 0
    local f = io.open("/etc/nginx/data/keys.json", "r")
    if f then
        local raw = f:read("*a")
        f:close()
        local parsed = cjson.decode(raw)
        if parsed then
            for key, user in pairs(parsed) do
                count = count + 1
                local masked = key:sub(1, 12) .. "..." .. key:sub(-6)
                keys_data[#keys_data + 1] = { key = masked, user = user }
            end
        end
    end
    ngx.say(cjson.encode({ keys = keys_data, count = count }))
    return
end

-- GET /internal/admin/overview — combined status for console
if uri == "/internal/admin/overview" and method == "GET" then
    -- Proxy mode
    local mode = os.getenv("PROXY_MODE") or "passthrough"
    local passthrough_user = os.getenv("PASSTHROUGH_USER") or ""

    -- Key count
    local key_count = 0
    local f = io.open("/etc/nginx/data/keys.json", "r")
    if f then
        local raw = f:read("*a")
        f:close()
        local parsed = cjson.decode(raw)
        if parsed then
            for _ in pairs(parsed) do key_count = key_count + 1 end
        end
    end

    -- Blocked count
    local blocked_count = 0
    local block_keys = blocking_dict:get_keys(0) or {}
    for _, key in ipairs(block_keys) do
        if key:sub(1, 8) == "blocked|" then
            blocked_count = blocked_count + 1
        end
    end

    -- Git-stats plugin active?
    local git_stats = false
    local gf = io.open("/etc/nginx/data/git-metrics.txt", "r")
    if gf then
        git_stats = true
        gf:close()
    end

    ngx.say(cjson.encode({
        proxy_mode = mode,
        passthrough_user = passthrough_user,
        key_count = key_count,
        blocked_count = blocked_count,
        plugins = { git_stats = git_stats },
    }))
    return
end

ngx.status = 404
ngx.say('{"error":"Unknown admin endpoint — available: /internal/admin/{block,unblock,limit,status,usage,keys,overview}"}')
