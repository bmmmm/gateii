-- admin_login.lua: validates ADMIN_TOKEN, issues/revokes HttpOnly session cookies.
-- POST /internal/admin/login  → verify token, set cookie
-- POST /internal/admin/logout → delete cookie, remove session from shared dict
local cjson = require "cjson.safe"
local sessions = ngx.shared.admin_sessions
local uri = ngx.var.uri

ngx.header["Content-Type"] = "application/json"

-- --- Logout ---
if uri == "/internal/admin/logout" then
    if ngx.req.get_method() ~= "POST" then
        ngx.status = 405
        ngx.say('{"error":"Method not allowed"}')
        return
    end
    -- Delete session from shared dict if cookie present
    local cookie_header = ngx.var.http_cookie or ""
    local session_id = cookie_header:match("admin_session=([a-f0-9]+)")
    if session_id then
        sessions:delete(session_id)
    end
    -- Clear cookie by expiring it immediately
    ngx.header["Set-Cookie"] = "admin_session=deleted; HttpOnly; Secure; SameSite=Strict; Path=/internal/admin; Max-Age=0"
    ngx.say('{"ok":true}')
    return
end

-- --- Login ---
if ngx.req.get_method() ~= "POST" then
    ngx.status = 405
    ngx.say('{"error":"Method not allowed"}')
    return
end

ngx.req.read_body()
local body = ngx.req.get_body_data()
local ADMIN_TOKEN = os.getenv("ADMIN_TOKEN") or ""

if ADMIN_TOKEN == "" then
    -- No token configured — console works without auth
    ngx.status = 200
    ngx.say('{"ok":true,"auth":"none"}')
    return
end

local supplied = ""
if body then
    local obj = cjson.decode(body)
    if obj then supplied = tostring(obj.token or "") end
end

if supplied ~= ADMIN_TOKEN then
    ngx.shared.counters:incr("admin_login_failures", 1, 0, 86400 * 7)
    ngx.status = 401
    ngx.say('{"error":"Invalid token"}')
    return
end

-- Generate session ID from /dev/urandom (32 bytes → 64 hex chars)
local urandom = io.open("/dev/urandom", "rb")
if not urandom then
    ngx.status = 500
    ngx.say('{"error":"Failed to open /dev/urandom"}')
    return
end
local raw = urandom:read(32)
urandom:close()
if not raw or #raw < 32 then
    ngx.status = 500
    ngx.say('{"error":"Failed to read random bytes"}')
    return
end
local hex_parts = {}
for i = 1, #raw do
    hex_parts[i] = string.format("%02x", raw:byte(i))
end
local session_id = table.concat(hex_parts)

sessions:set(session_id, "1", 3600)  -- 1h TTL

ngx.header["Set-Cookie"] = "admin_session=" .. session_id
    .. "; HttpOnly; Secure; SameSite=Strict; Path=/internal/admin; Max-Age=3600"
ngx.say('{"ok":true}')
