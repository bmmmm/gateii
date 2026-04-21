-- console_serve.lua: serves /console HTML with per-request CSP nonce.
-- Auth is handled via HttpOnly session cookie issued by /internal/admin/login —
-- no token injection into the DOM.
--
-- CSP nonce approach: /dev/urandom → 16 bytes → base64url nonce injected into
--   script-src 'nonce-<value>' and each <script> tag in the HTML.
-- style-src retains 'unsafe-inline': removing it requires extracting all inline
--   styles to a separate stylesheet — out of scope for this change.
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

-- Generate a per-request nonce from /dev/urandom (16 bytes → base64url)
local nonce = ""
local urandom = io.open("/dev/urandom", "rb")
if urandom then
    local raw = urandom:read(16)
    urandom:close()
    if raw and #raw == 16 then
        -- ngx.encode_base64 is always available in OpenResty
        local b64str = ngx.encode_base64(raw)
        -- Convert standard base64 to base64url (replace +→-, /→_, strip =)
        nonce = b64str:gsub("+", "-"):gsub("/", "_"):gsub("=", "")
    end
end

-- Fallback: use request_id if /dev/urandom failed (less ideal but safe)
if nonce == "" then
    nonce = (ngx.var.request_id or ""):gsub("[^a-zA-Z0-9]", "")
    if nonce == "" then nonce = tostring(ngx.now()):gsub("[^a-zA-Z0-9]", "") end
end

-- Inject nonce attribute into every <script> opening tag (no src= — inline only)
-- This covers both <script> and <script type="..."> but not external <script src=...>
html = html:gsub("<script>", '<script nonce="' .. nonce .. '">')
html = html:gsub('<script%s+type="([^"]*)">', function(t)
    return '<script type="' .. t .. '" nonce="' .. nonce .. '">'
end)

ngx.header["Content-Security-Policy"] =
    "default-src 'self'; " ..
    -- style-src keeps unsafe-inline: extracting ~180 lines of inline CSS to a
    -- separate file is invasive and out of scope; nonce on scripts is the win.
    -- Google Fonts stylesheet is loaded via <link>; needs style-src allowance.
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; " ..
    "script-src 'nonce-" .. nonce .. "'; " ..
    "img-src 'self' data:; " ..
    "connect-src 'self'; " ..
    "font-src https://fonts.gstatic.com; " ..
    "base-uri 'self'; " ..
    "form-action 'self'; " ..
    "frame-ancestors 'none'"
ngx.header["X-Content-Type-Options"] = "nosniff"
ngx.header["Referrer-Policy"] = "no-referrer"

ngx.print(html)
