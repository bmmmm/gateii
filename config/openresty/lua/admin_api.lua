-- admin_api.lua: internal admin endpoints for blocking/unblocking
local cjson = require "cjson.safe"
local blocking_dict = ngx.shared.blocking
local counters = ngx.shared.counters

local method = ngx.req.get_method()
local uri = ngx.var.uri

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
    ngx.say('{"ok":true,"user":"' .. user .. '","ttl":' .. ttl .. '}')
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
    ngx.say('{"ok":true,"user":"' .. user .. '"}')
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
    ngx.say('{"ok":true,"user":"' .. user .. '"}')
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

ngx.status = 404
ngx.say('{"error":"Unknown admin endpoint — available: /internal/admin/{block,unblock,limit,status,usage}"}')
