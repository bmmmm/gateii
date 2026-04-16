-- console_serve.lua: serves /console HTML with ADMIN_TOKEN injected as a
-- meta tag. Fetches from the console JS use that token as X-Admin-Token
-- so the admin API stays reachable when ADMIN_TOKEN is set.
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

local token = os.getenv("ADMIN_TOKEN") or ""
if token ~= "" then
    -- Escape in order: & first so later replacements are not double-encoded.
    token = token:gsub("&", "&amp;")
                 :gsub('"', "&quot;")
                 :gsub("<", "&lt;")
                 :gsub(">", "&gt;")
    html = html:gsub("</head>",
        '<meta name="admin-token" content="' .. token .. '"></head>', 1)
end

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
