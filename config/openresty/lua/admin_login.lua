-- admin_login.lua: validates ADMIN_TOKEN, issues HttpOnly session cookie
local cjson = require "cjson.safe"
local sessions = ngx.shared.admin_sessions

math.randomseed(ngx.now() * 1000 + ngx.worker.id())

if ngx.req.get_method() ~= "POST" then
    ngx.status = 405
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Method not allowed"}')
    return
end

ngx.req.read_body()
local body = ngx.req.get_body_data()
local ADMIN_TOKEN = os.getenv("ADMIN_TOKEN") or ""

if ADMIN_TOKEN == "" then
    -- No token configured — console works without auth
    ngx.status = 200
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"ok":true,"auth":"none"}')
    return
end

local supplied = ""
if body then
    local obj = cjson.decode(body)
    if obj then supplied = tostring(obj.token or "") end
end

if supplied ~= ADMIN_TOKEN then
    ngx.status = 401
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Invalid token"}')
    return
end

-- Generate session ID (32 hex chars from random bytes)
local bytes = {}
for i = 1, 16 do bytes[i] = string.format("%02x", math.random(0, 255)) end
local session_id = table.concat(bytes)

sessions:set(session_id, "1", 3600)  -- 1h TTL

ngx.header["Set-Cookie"] = "admin_session=" .. session_id
    .. "; HttpOnly; SameSite=Strict; Path=/internal/admin; Max-Age=3600"
ngx.header["Content-Type"] = "application/json"
ngx.say('{"ok":true}')
