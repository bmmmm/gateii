-- console_serve.lua: serves /console HTML. Auth is handled via HttpOnly session
-- cookie issued by /internal/admin/login — no token injection into the DOM.
if os.getenv("CONSOLE_ENABLED") ~= "1" then
    ngx.status = 404
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Console not enabled — set CONSOLE_ENABLED=1 in .env or run: admin.sh plugin enable console"}')
    return ngx.exit(404)
end

local f = io.open("/etc/nginx/html/console.html", "r")
if not f then
    ngx.status = 500
    ngx.say("console.html missing")
    return
end
local html = f:read("*a"); f:close()

ngx.header["Content-Security-Policy"] =
    "default-src 'self'; " ..
    "style-src 'self' 'unsafe-inline'; " ..
    "script-src 'self' 'unsafe-inline'; " ..
    "img-src 'self' data:; " ..
    "connect-src 'self'; " ..
    "base-uri 'self'; " ..
    "form-action 'self'; " ..
    "frame-ancestors 'none'"
ngx.header["X-Content-Type-Options"] = "nosniff"
ngx.header["Referrer-Policy"] = "no-referrer"

ngx.print(html)
