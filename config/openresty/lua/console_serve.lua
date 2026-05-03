-- console_serve.lua: route /console/ and /console/compare to their HTML files,
-- enforce CONSOLE_ENABLED=1, set CSP. The bulk of the page (CSS + JS) lives
-- in /console/static/* and is served directly by nginx.
--
-- Why no nonce: scripts are loaded via <script src="/console/static/...">
-- — same-origin allowance covers them. The single inline <script> on each
-- page is just a one-liner DOMContentLoaded init call. CSP allows
-- 'unsafe-inline' for scripts to keep this trivially-small inline alive
-- without per-request nonces (the static JS files are the meaningful
-- attack surface and they're under our control).

if os.getenv("CONSOLE_ENABLED") ~= "1" then
    ngx.status = 404
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Console not enabled — set CONSOLE_ENABLED=1 in .env or run: admin.sh plugin enable console"}')
    return ngx.exit(404)
end

local uri = ngx.var.uri or "/console/"
local html_file
if uri == "/console/" or uri == "/console/index.html" then
    html_file = "/etc/nginx/html/console/index.html"
elseif uri == "/console/compare" or uri == "/console/compare.html" then
    html_file = "/etc/nginx/html/console/compare.html"
else
    ngx.status = 404
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"console page not found: ' .. uri .. '"}')
    return ngx.exit(404)
end

local f = io.open(html_file, "r")
if not f then
    ngx.status = 500
    ngx.say(html_file .. " missing")
    return
end
local html = f:read("*a"); f:close()

ngx.header["Content-Security-Policy"] =
    "default-src 'self'; " ..
    "style-src 'self' 'unsafe-inline'; " ..
    "script-src 'self' 'unsafe-inline'; " ..
    "img-src 'self' data:; " ..
    "connect-src 'self'; " ..
    "font-src 'self'; " ..
    "base-uri 'self'; " ..
    "form-action 'self'; " ..
    "frame-ancestors 'none'"
ngx.header["Referrer-Policy"] = "no-referrer"

ngx.print(html)
