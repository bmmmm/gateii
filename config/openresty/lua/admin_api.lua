-- admin_api.lua: internal admin endpoints for blocking/unblocking
local cjson = require "cjson.safe"
local schema = require "schema"
local util = require "util"
local blocking_dict = ngx.shared.blocking
local counters = ngx.shared.counters

local method = ngx.req.get_method()
local uri = ngx.var.uri

ngx.header["Content-Type"] = "application/json"

-- Defense-in-depth auth: require X-Admin-Token header or valid session cookie when
-- ADMIN_TOKEN env is set. Protects against lateral movement from a compromised container
-- on the Docker network; the IP allow-list in nginx.conf alone trusts every sidecar.
local ADMIN_TOKEN = os.getenv("ADMIN_TOKEN") or ""
local PROXY_MODE = os.getenv("PROXY_MODE") or "apikey"

-- Per-component health-check timeouts (ms). Defaults tuned for LAN-local services.
-- Override via env when hitting slower backends.
local HEALTH_CHECK_CONNECT_MS = tonumber(os.getenv("HEALTH_CHECK_CONNECT_MS")) or 1500
local HEALTH_CHECK_SEND_MS    = tonumber(os.getenv("HEALTH_CHECK_SEND_MS"))    or 1500
local HEALTH_CHECK_READ_MS    = tonumber(os.getenv("HEALTH_CHECK_READ_MS"))    or 3000

if ADMIN_TOKEN == "" and PROXY_MODE == "apikey" then
    -- Fail-closed: apikey mode without token exposes keys.json/limits.json
    -- mutations to anyone on the admin network. Require a token.
    ngx.status = 503
    ngx.say('{"error":"Admin API disabled — set ADMIN_TOKEN in .env"}')
    return ngx.exit(503)
end

if ADMIN_TOKEN ~= "" then
    local supplied_header = ngx.var.http_x_admin_token or ""
    local authed = false

    local bootstrap = require "bootstrap"
    if bootstrap._consttime_eq(supplied_header, ADMIN_TOKEN) then
        authed = true
    else
        -- Check session cookie
        local cookie_header = ngx.var.http_cookie or ""
        local session_id = cookie_header:match("admin_session=([a-f0-9]+)")
        if session_id then
            local sessions = ngx.shared.admin_sessions
            local valid = sessions:get(session_id)
            if valid then
                -- Refresh TTL on activity
                sessions:set(session_id, "1", 3600)
                authed = true
            end
        end
    end

    if not authed then
        ngx.status = 401
        ngx.say('{"error":"Unauthorized — use X-Admin-Token header or login via /internal/admin/login"}')
        return ngx.exit(401)
    end
end

local LIMITS_FILE = "/etc/nginx/data/limits.json"
local MAX_ITER_KEYS = 5000

-- Sanitize user for key construction
local function sanitize(s)
    return (tostring(s or ""):gsub("[:|%s]", "_"):sub(1, 64))
end

-- Read keys.json, return table (may be empty)
local function read_keys_file()
    local f = io.open("/etc/nginx/data/keys.json", "r")
    if not f then return {} end
    local raw = f:read("*a"); f:close()
    return cjson.decode(raw) or {}
end

-- Validate user param from request args; send 400 and return nil on missing
local function require_user(args)
    local u = sanitize(args.user or "")
    if u == "" then
        ngx.status = 400
        ngx.say('{"error":"Missing user parameter"}')
        return nil
    end
    return u
end

-- Persist limits to disk (survives container restarts)
local function save_limits()
    local all = {}
    local keys = blocking_dict:get_keys(MAX_ITER_KEYS)
    for _, key in ipairs(keys) do
        if key:sub(1, 7) == "limits|" then
            local u = key:sub(8)
            local raw = blocking_dict:get(key)
            if raw then
                local decoded, err = cjson.decode(raw)
                if decoded then
                    all[u] = decoded
                else
                    ngx.log(ngx.ERR, "save_limits: skipping corrupt entry key=", key, " err=", tostring(err))
                end
            end
        end
    end
    local encoded = cjson.encode(all)
    if not encoded then
        ngx.log(ngx.ERR, "save_limits: cjson.encode failed")
        return
    end
    local ok, err = util.atomic_write(LIMITS_FILE, encoded)
    if not ok then
        ngx.log(ngx.ERR, "save_limits: ", err)
    end
end

-- POST /internal/admin/block?user=X&ttl=86400
if uri == "/internal/admin/block" and method == "POST" then
    local args = ngx.req.get_uri_args()
    local user = require_user(args); if not user then return end
    local ttl = tonumber(args.ttl) or 86400
    local bok, berr = blocking_dict:set("blocked|" .. user, "manual", ttl)
    if not bok then
        ngx.log(ngx.ERR, "admin: block set failed key=blocked|", user, " err=", berr,
                " free=", blocking_dict:free_space())
        ngx.status = 500
        ngx.say('{"error":"Failed to persist limits — shared dict full"}')
        return
    end
    ngx.say(cjson.encode({ok = true, user = user, ttl = ttl}))
    return
end

-- POST /internal/admin/unblock?user=X
if uri == "/internal/admin/unblock" and method == "POST" then
    local args = ngx.req.get_uri_args()
    local user = require_user(args); if not user then return end
    blocking_dict:delete("blocked|" .. user)
    ngx.say(cjson.encode({ok = true, user = user}))
    return
end

-- POST /internal/admin/limit?user=X  body: {"tokens_per_day":N,"requests_per_day":N}
if uri == "/internal/admin/limit" and method == "POST" then
    ngx.req.read_body()
    local args = ngx.req.get_uri_args()
    local user = require_user(args); if not user then return end
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
    -- Validate field types — prevent negative or non-numeric values reaching auth.lua
    local function is_pos_int(v)
        return type(v) == "number" and v > 0 and math.floor(v) == v
    end
    if limits.tokens_per_day ~= nil and not is_pos_int(limits.tokens_per_day) then
        ngx.status = 400
        ngx.say('{"error":"tokens_per_day must be a positive integer"}')
        return
    end
    if limits.tokens_per_day ~= nil and limits.tokens_per_day > 10000000 then
        ngx.status = 400
        ngx.say('{"error":"tokens_per_day exceeds maximum (10000000)"}')
        return
    end
    if limits.requests_per_day ~= nil and not is_pos_int(limits.requests_per_day) then
        ngx.status = 400
        ngx.say('{"error":"requests_per_day must be a positive integer"}')
        return
    end
    if limits.requests_per_day ~= nil and limits.requests_per_day > 100000 then
        ngx.status = 400
        ngx.say('{"error":"requests_per_day exceeds maximum (100000)"}')
        return
    end
    if limits.tokens_per_day == nil and limits.requests_per_day == nil then
        ngx.status = 400
        ngx.say('{"error":"Provide at least one of: tokens_per_day, requests_per_day"}')
        return
    end
    local lok, lerr = blocking_dict:set("limits|" .. user, cjson.encode(limits), 90 * 86400)
    if not lok then
        ngx.log(ngx.ERR, "admin: limits set failed key=limits|", user, " err=", lerr,
                " free=", blocking_dict:free_space())
        ngx.status = 500
        ngx.say('{"error":"Failed to persist limits — shared dict full"}')
        return
    end
    save_limits()
    ngx.say(cjson.encode({ok = true, user = user}))
    return
end

-- GET /internal/admin/status
if uri == "/internal/admin/status" and method == "GET" then
    local blocked = {}
    local block_keys = blocking_dict:get_keys(MAX_ITER_KEYS)
    for _, key in ipairs(block_keys) do
        if key:sub(1, 8) == "blocked|" then
            local buser = key:sub(9)
            -- :ttl() returns -1 for no-expire keys and -2 for missing; clamp to 0
            local ttl = blocking_dict:ttl(key) or 0
            if ttl < 0 then ttl = 0 end
            blocked[#blocked + 1] = { user = buser, ttl = math.ceil(ttl) }
        end
    end
    -- Collect limits
    local limits = {}
    for _, key in ipairs(block_keys) do
        if key:sub(1, 7) == "limits|" then
            local luser = key:sub(8)
            local raw = blocking_dict:get(key)
            if raw then
                local ldata = cjson.decode(raw)
                if ldata then
                    ldata.user = luser
                    limits[#limits + 1] = ldata
                end
            end
        end
    end

    -- Force empty tables to encode as JSON []
    local result = '{"blocked":' .. (#blocked > 0 and cjson.encode(blocked) or '[]')
                .. ',"limits":' .. (#limits > 0 and cjson.encode(limits) or '[]') .. '}'
    ngx.say(result)
    return
end

-- GET /internal/admin/usage?user=X
if uri == "/internal/admin/usage" and method == "GET" then
    local args = ngx.req.get_uri_args()
    local user = require_user(args); if not user then return end
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
    local parsed = read_keys_file()
    local keys_data = {}
    for key, entry in pairs(parsed) do
        local masked_key = key:sub(1, 12) .. "..." .. key:sub(-6)
        local row = { key = masked_key }
        if type(entry) == "table" then
            row.user         = entry.user
            row.provider     = entry.provider
            local uk = entry.upstream_key or ""
            -- Mask upstream key: first 6 + last 4 when long enough, else show full
            if #uk > 12 then
                row.upstream_key = uk:sub(1, 6) .. "***" .. uk:sub(-4)
            else
                row.upstream_key = uk
            end
            row.created_at = entry.created_at
        else
            -- Defensive: legacy flat entries shouldn't pass schema validation anymore
            row.user = tostring(entry)
        end
        keys_data[#keys_data + 1] = row
    end
    ngx.say(cjson.encode({ keys = keys_data, count = #keys_data }))
    return
end

-- GET /internal/admin/overview — combined status for console
if uri == "/internal/admin/overview" and method == "GET" then
    -- Proxy mode
    local mode = os.getenv("PROXY_MODE") or "apikey"
    local passthrough_user = os.getenv("PASSTHROUGH_USER") or ""

    -- Key count
    local key_count = 0
    for _ in pairs(read_keys_file()) do key_count = key_count + 1 end

    -- Blocked count
    local blocked_count = 0
    local block_keys = blocking_dict:get_keys(MAX_ITER_KEYS) or {}
    for _, key in ipairs(block_keys) do
        if key:sub(1, 8) == "blocked|" then
            blocked_count = blocked_count + 1
        end
    end

    -- Git-stats plugin active?
    local git_tracking = false
    local gf = io.open("/etc/nginx/data/git-metrics.txt", "r")
    if gf then
        git_tracking = true
        gf:close()
    end

    local console_enabled = os.getenv("CONSOLE_ENABLED") == "1"

    ngx.say(cjson.encode({
        proxy_mode = mode,
        passthrough_user = passthrough_user,
        key_count = key_count,
        blocked_count = blocked_count,
        plugins = { console = console_enabled, git_tracking = git_tracking },
    }))
    return
end

-- GET /internal/admin/usage-all — all users' daily counters + limits for console
if uri == "/internal/admin/usage-all" and method == "GET" then
    local today = os.date("!%Y-%m-%d")
    local users = {}
    local truncated = false

    -- Collect all day|*|today|* keys from counters
    local all_keys = counters:get_keys(MAX_ITER_KEYS)
    if #all_keys >= MAX_ITER_KEYS then truncated = true end
    for _, key in ipairs(all_keys) do
        -- Match: day|<user>|<date>|<field>
        local u, date, field = key:match("^day|([^|]+)|([^|]+)|(.+)$")
        if u and date == today then
            if not users[u] then users[u] = { user = u, input = 0, output = 0, requests = 0 } end
            local val = counters:get(key) or 0
            if field == "input" then users[u].input = val
            elseif field == "output" then users[u].output = val
            elseif field == "requests" then users[u].requests = val end
        end
    end

    -- Attach limits and block status per user
    local block_keys = blocking_dict:get_keys(MAX_ITER_KEYS)
    if #block_keys >= MAX_ITER_KEYS then truncated = true end
    for _, key in ipairs(block_keys) do
        if key:sub(1, 7) == "limits|" then
            local luser = key:sub(8)
            if not users[luser] then users[luser] = { user = luser, input = 0, output = 0, requests = 0 } end
            local raw = blocking_dict:get(key)
            if raw then
                local ldata = cjson.decode(raw)
                if ldata then
                    users[luser].tokens_limit = ldata.tokens_per_day
                    users[luser].requests_limit = ldata.requests_per_day
                end
            end
        end
    end

    -- Convert to array
    local result = {}
    for _, u in pairs(users) do
        result[#result + 1] = u
    end
    table.sort(result, function(a, b) return a.user < b.user end)

    if #result == 0 and not truncated then
        ngx.say('[]')
    else
        local payload = cjson.encode(result)
        if truncated then
            -- Inject truncated flag: wrap in object so callers can detect partial results
            ngx.say('{"users":' .. payload .. ',"truncated":true}')
        else
            ngx.say(payload)
        end
    end
    return
end

-- POST /internal/admin/addkey?user=X
--   body: {"key":"sk-proxy-...","provider":"anthropic","upstream_key":"sk-ant-..."}
if uri == "/internal/admin/addkey" and method == "POST" then
    ngx.req.read_body()
    local args = ngx.req.get_uri_args()
    local user = sanitize(args.user or "")
    if user == "" then
        ngx.status = 400
        ngx.say('{"error":"Missing user parameter"}')
        return
    end

    local body = ngx.req.get_body_data()
    local key, provider, upstream_key = "", "", ""
    if body then
        local obj = cjson.decode(body)
        if obj then
            key          = tostring(obj.key or "")
            provider     = tostring(obj.provider or "")
            upstream_key = tostring(obj.upstream_key or "")
        end
    end
    if key == "" or provider == "" or upstream_key == "" then
        ngx.status = 400
        ngx.say('{"error":"Missing fields — JSON body requires: {key, provider, upstream_key}"}')
        return
    end
    -- Validate key length + format
    if #key < 8 then
        ngx.status = 400; ngx.say('{"error":"API key too short — min 8 chars"}'); return
    end
    if #key > 256 then
        ngx.status = 400; ngx.say('{"error":"API key too long — max 256 chars"}'); return
    end
    if not key:match("^sk%-proxy%-[a-f0-9]+$") and not key:match("^sk%-[a-zA-Z0-9_%-]+$") then
        ngx.status = 400; ngx.say('{"error":"Invalid key format"}'); return
    end
    if #upstream_key < 8 then
        ngx.status = 400; ngx.say('{"error":"upstream_key too short — min 8 chars"}'); return
    end
    if #upstream_key > 512 then
        ngx.status = 400; ngx.say('{"error":"upstream_key too long — max 512 chars"}'); return
    end
    if not provider:match("^[a-z][a-z0-9_]+$") then
        ngx.status = 400; ngx.say('{"error":"provider must match ^[a-z][a-z0-9_]+$"}'); return
    end

    local keys_data = read_keys_file()
    keys_data[key] = {
        user          = user,
        provider      = provider,
        upstream_key  = upstream_key,
        created_at    = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    local encoded = cjson.encode(keys_data)
    if not encoded then
        ngx.status = 500; ngx.say('{"error":"Failed to encode keys"}'); return
    end
    local rok, rerr = util.atomic_write("/etc/nginx/data/keys.json", encoded)
    if not rok then
        ngx.log(ngx.ERR, "addkey: ", rerr)
        ngx.status = 500; ngx.say('{"error":"Failed to persist keys.json — check server logs"}'); return
    end
    -- Clear any negative cache entry so the new key is usable immediately
    ngx.shared.auth_cache:delete(key)
    ngx.say(cjson.encode({ ok = true, user = user, provider = provider }))
    return
end

-- GET /internal/admin/providers — multi-provider pricing config
if uri == "/internal/admin/providers" and method == "GET" then
    local f = io.open("/etc/nginx/lua/providers.json", "r")
    if not f then
        ngx.status = 404
        ngx.say('{"error":"providers.json not found — create config/openresty/lua/providers.json"}')
        return
    end
    local data = f:read("*a")
    f:close()
    ngx.say(data)
    return
end

-- GET /internal/admin/llm-prices — proxy llm-prices.com with 1hr cache
if uri == "/internal/admin/llm-prices" and method == "GET" then
    local cache_key = "llm_prices_cache"
    local cached = counters:get(cache_key)

    -- Return cached data if fresh (< 1hr)
    if cached then
        ngx.header["X-Cache"] = "HIT"
        ngx.say(cached)
        return
    end

    -- Fetch from llm-prices.com
    ngx.header["X-Cache"] = "MISS"
    local http = require "resty.http"
    local httpc = http.new()
    httpc:set_timeouts(5000, 5000, 10000)
    local res, err = httpc:request_uri("https://www.llm-prices.com/current-v1.json", {
        ssl_verify = true,
        headers = { ["User-Agent"] = "gateii-proxy/1.0" },
    })
    if not res then
        ngx.status = 502
        ngx.say(cjson.encode({error = "Failed to fetch llm-prices: " .. (err or "unknown")}))
        return
    end
    if res.status ~= 200 then
        ngx.status = res.status
        ngx.say(cjson.encode({error = "llm-prices returned HTTP " .. res.status}))
        return
    end

    -- Cache for 1hr (3600s) — uses counters dict for storage
    local ok, cerr = counters:set(cache_key, res.body, 3600)
    if not ok then
        ngx.log(ngx.WARN, "llm-prices cache write failed: ", cerr)
    end

    ngx.say(res.body)
    return
end

-- GET /internal/admin/openrouter-models — proxy OpenRouter model list (12h cache)
-- Returns slim pricing index: {models:[{id,name,input,output},...]}
if uri == "/internal/admin/openrouter-models" and method == "GET" then
    local cache_key = "openrouter_models"
    local cached = counters:get(cache_key)
    if cached then
        ngx.header["X-Cache"] = "HIT"
        ngx.say(cached)
        return
    end

    ngx.header["X-Cache"] = "MISS"
    local http = require "resty.http"
    local httpc = http.new()
    httpc:set_timeouts(5000, 5000, 15000)
    local res, err = httpc:request_uri("https://openrouter.ai/api/v1/models?order=top-weekly&categories=programming", {
        ssl_verify = true,
        headers = { ["User-Agent"] = "gateii-proxy/1.0", ["Accept"] = "application/json" },
    })
    if not res then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "openrouter fetch failed: " .. (err or "unknown") }))
        return
    end
    if res.status ~= 200 then
        ngx.status = res.status
        ngx.say(cjson.encode({ error = "openrouter returned HTTP " .. res.status }))
        return
    end

    local full = cjson.decode(res.body)
    if not full or not full.data then
        ngx.status = 502
        ngx.say(cjson.encode({ error = "openrouter response malformed" }))
        return
    end

    -- Extract only id + pricing to keep cache small
    local models = {}
    for _, m in ipairs(full.data) do
        if m.id and m.pricing then
            local inp = tonumber(m.pricing.prompt) or 0
            local out = tonumber(m.pricing.completion) or 0
            models[#models + 1] = {
                id     = m.id,
                name   = m.name or m.id,
                input  = inp * 1e6,   -- convert per-token → $/MTok
                output = out * 1e6,
            }
        end
    end

    local result = cjson.encode({ models = models })
    local ok, cerr = counters:set(cache_key, result, 43200)  -- 12h
    if not ok then
        ngx.log(ngx.WARN, "openrouter cache write failed: ", cerr)
    end

    ngx.say(result)
    return
end

-- GET /internal/admin/health — component reachability (parallel via ngx.thread)
if uri == "/internal/admin/health" and method == "GET" then
    local http = require "resty.http"

    local function check(url)
        local t0 = ngx.now()
        local httpc = http.new()
        httpc:set_timeouts(HEALTH_CHECK_CONNECT_MS, HEALTH_CHECK_SEND_MS, HEALTH_CHECK_READ_MS)
        local res, err = httpc:request_uri(url)
        local ms = math.floor((ngx.now() - t0) * 1000)
        if res and res.status < 500 then
            return { ok = true, latency_ms = ms }
        end
        return { ok = false, latency_ms = ms, error = err or ("HTTP " .. (res and res.status or "?")) }
    end

    -- Run Prometheus + Grafana checks in parallel
    local t_prom = ngx.thread.spawn(check, "http://gateii-prometheus:9090/-/healthy")
    local t_graf = ngx.thread.spawn(check, "http://gateii-grafana:3000/api/health")
    local _, prom = ngx.thread.wait(t_prom)
    local _, graf = ngx.thread.wait(t_graf)

    -- Upstream error rate from counters (no network call needed)
    local all_req, all_err = 0, 0
    for _, key in ipairs(counters:get_keys(MAX_ITER_KEYS)) do
        local parts = {}
        for p in key:gmatch("[^|]+") do parts[#parts+1] = p end
        if #parts == 4 and parts[1] ~= "day" then
            if parts[4] == "requests" then all_req = all_req + (counters:get(key) or 0)
            elseif parts[4] == "errors"   then all_err = all_err + (counters:get(key) or 0) end
        end
    end
    local err_rate = all_req > 0 and all_err / all_req or 0
    local upstream = {
        ok         = err_rate < 0.1,
        requests   = all_req,
        errors     = all_err,
        error_rate = math.floor(err_rate * 1000) / 10,  -- percent, 1 decimal
    }

    local components = { proxy = { ok = true, latency_ms = 0 }, prometheus = prom, grafana = graf, upstream = upstream }
    local down = 0
    for _, v in pairs(components) do if not v.ok then down = down + 1 end end
    local status = down == 0 and "ok" or (down >= 2 and "down" or "degraded")

    ngx.say(cjson.encode({ status = status, components = components }))
    return
end

-- Bootstrap admin endpoints (protected by same admin auth as the rest)
--   POST   /internal/admin/bootstrap          — create bootstrap (body: {user, provider, upstream_key, ttl?})
--   GET    /internal/admin/bootstrap          — list pending + sessions
--   DELETE /internal/admin/bootstrap/<code>   — revoke a pending bootstrap
do
    local is_bootstrap = uri == "/internal/admin/bootstrap"
        or uri:sub(1, #"/internal/admin/bootstrap/") == "/internal/admin/bootstrap/"
    if is_bootstrap then
        local ok_req, bootstrap = pcall(require, "bootstrap")
        if not ok_req then
            ngx.status = 500
            ngx.say('{"error":"bootstrap module unavailable"}')
            return
        end

        if uri == "/internal/admin/bootstrap" and method == "POST" then
            ngx.req.read_body()
            local raw = ngx.req.get_body_data()
            local body = raw and cjson.decode(raw) or nil
            if type(body) ~= "table" then
                ngx.status = 400; ngx.say('{"error":"Missing JSON body"}'); return
            end
            local result, err = bootstrap.create(body)
            if not result then
                ngx.status = 400; ngx.say(cjson.encode({ error = err or "create failed" })); return
            end
            ngx.say(cjson.encode(result))
            return
        end

        if uri == "/internal/admin/bootstrap" and method == "GET" then
            ngx.say(cjson.encode(bootstrap.list()))
            return
        end

        if method == "DELETE" and uri:sub(1, #"/internal/admin/bootstrap/") == "/internal/admin/bootstrap/" then
            local code = uri:sub(#"/internal/admin/bootstrap/" + 1)
            local ok, err = bootstrap.revoke_code(code)
            if not ok then
                ngx.status = (err == "not_found") and 404 or 400
                ngx.say(cjson.encode({ error = err or "revoke failed" }))
                return
            end
            ngx.say(cjson.encode({ ok = true, code = code }))
            return
        end

        ngx.status = 405
        ngx.say('{"error":"Method not allowed on bootstrap endpoint"}')
        return
    end
end

-- /internal/admin/diagnostics — single-shot snapshot of everything an
-- operator (or a future-Claude debugging via the API) needs to assess
-- gateii's current state. Aggregates: proxy mode, plugin config,
-- shared-dict free space, rate-limit window state, services list (via
-- compose-ctl), upstream health probe summary. Read-only; same auth
-- as every other admin endpoint.
if uri == "/internal/admin/diagnostics" and method == "GET" then
    local cd = ngx.shared.counters

    -- Soft rate-limit: 6 calls/min/client. Admin auth is the real defense;
    -- this is a detection-signal cap so a runaway script or a compromised
    -- session can't hammer the endpoint silently. Returns 429 + Retry-After.
    local DIAG_RATE_LIMIT_PER_MIN = 6
    local rl_key = "diag_rl|" .. (ngx.var.remote_addr or "?")
    local count = cd:incr(rl_key, 1, 0, 60) or 0
    if count > DIAG_RATE_LIMIT_PER_MIN then
        ngx.status = 429
        ngx.header["Retry-After"] = "60"
        ngx.say(cjson.encode({
            error = "rate_limit",
            limit_per_min = DIAG_RATE_LIMIT_PER_MIN,
            window_seconds = 60,
        }))
        return
    end

    -- Optional ?include=services,rate_limits,plugins,totals,shared_dicts,proxy
    -- to scope the response. Useful when piping diagnostics to less-privileged
    -- tools (monitoring, backup) that don't need image versions / uptimes.
    local args = ngx.req.get_uri_args()
    local include_set
    if args.include and args.include ~= "" then
        include_set = {}
        for k in tostring(args.include):gmatch("[^,%s]+") do
            include_set[k] = true
        end
    end
    local function want(section)
        return include_set == nil or include_set[section] == true
    end

    local out = { timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ") }

    if want("proxy") then
        out.proxy_mode = os.getenv("PROXY_MODE") or "apikey"
        out.passthrough_user = os.getenv("PASSTHROUGH_USER") or ""
    end

    if want("shared_dicts") then
        out.shared_dicts = {
            counters       = ngx.shared.counters       and ngx.shared.counters:free_space()       or nil,
            blocking       = ngx.shared.blocking       and ngx.shared.blocking:free_space()       or nil,
            admin_sessions = ngx.shared.admin_sessions and ngx.shared.admin_sessions:free_space() or nil,
            auth_cache     = ngx.shared.auth_cache     and ngx.shared.auth_cache:free_space()     or nil,
        }
    end

    if want("rate_limits") then
        out.rate_limits = {
            util_5h        = tonumber(cd:get("ratelimit_5h_utilization")),
            util_7d        = tonumber(cd:get("ratelimit_7d_utilization")),
            tokens_remaining = tonumber(cd:get("ratelimit_remaining")),
            tokens_window_max = tonumber(cd:get("tokens_window_limit")),
            reset_5h_ts    = cd:get("ratelimit_reset_ts"),
            reset_7d_ts    = cd:get("ratelimit_7d_reset_ts"),
            fallback_pct   = tonumber(cd:get("ratelimit_fallback_pct")),
            tokens_expired_last_window = tonumber(cd:get("ratelimit_tokens_expired")),
        }
    end

    if want("totals") then
        local t = { requests = 0, errors = 0, input = 0, output = 0,
                    cache_read = 0, cache_creation = 0 }
        -- Only the 4-part base counter `user|provider|model|<field>` — skip
        -- the parallel `day|...` rollups and `user|provider|model|effort|...`
        -- / `|modality|...` dimensional counters which all share the same
        -- field-name suffix and would 4× the numbers if added together.
        for _, key in ipairs(cd:get_keys(5000) or {}) do
            local _, pipes = key:gsub("|", "")
            if pipes == 3 and key:sub(1, 4) ~= "day|" then
                local field = key:match("|([^|]+)$")
                if field and t[field] ~= nil then
                    t[field] = t[field] + (cd:get(key) or 0)
                end
            end
        end
        out.totals = {
            requests = t.requests,
            upstream_errors = t.errors,
            input_tokens = t.input,
            output_tokens = t.output,
            cache_read_tokens = t.cache_read,
            cache_creation_tokens = t.cache_creation,
        }
    end

    if want("services") then
        local http = require "resty.http"
        local httpc = http.new()
        httpc:set_timeouts(1000, 1000, 3000)
        local res, err = httpc:request_uri("http://compose-ctl:8090/services")
        if res and res.status == 200 then
            out.services = cjson.decode(res.body) or { error = "decode failed" }
        else
            out.services = { error = "compose-ctl unreachable: " .. tostring(err or res and res.status) }
        end
    end

    if want("plugins") then
        local gf = io.open("/etc/nginx/data/git-metrics.txt", "r")
        if gf then gf:close() end
        out.plugins = {
            console = { configured = os.getenv("CONSOLE_ENABLED") == "1" },
            git_tracking = {
                configured = os.getenv("GIT_TRACKING_ENABLED") == "1",
                metrics_file_present = gf ~= nil,
            },
        }
        out.admin_login_failures_7d = tonumber(cd:get("admin_login_failures")) or 0
    end

    -- Agents-page diagnostics: omlx connectivity + bench/routing freshness +
    -- log volume + active state. Each section answers a likely "why doesn't
    -- the agents tab show what I expect?" question.
    if want("agents") then
        local AGENTS_DIR = "/etc/nginx/data/agents"
        local function file_meta(path)
            local f = io.open(path, "r")
            if not f then return { present = false } end
            local size = f:seek("end") or 0
            f:close()
            local m = { present = true, size = size }
            return m
        end
        local function jsonl_count(path)
            local f = io.open(path, "r")
            if not f then return 0 end
            local n = 0
            for _ in f:lines() do n = n + 1 end
            f:close()
            return n
        end

        out.agents = {
            omlx_url           = os.getenv("OMLX_URL")     or "(unset)",
            omlx_api_key_set   = (os.getenv("OMLX_API_KEY") or "") ~= "",
            files = {
                ["active.json"]       = file_meta(AGENTS_DIR .. "/active.json"),
                ["log.jsonl"]         = file_meta(AGENTS_DIR .. "/log.jsonl"),
                ["routing.json"]      = file_meta(AGENTS_DIR .. "/routing.json"),
                ["bench-results.json"]= file_meta(AGENTS_DIR .. "/bench-results.json"),
                ["bench-report.md"]   = file_meta(AGENTS_DIR .. "/bench-report.md"),
                ["lock.d (held)"]     = file_meta(AGENTS_DIR .. "/lock.d"),
            },
            log_run_count = jsonl_count(AGENTS_DIR .. "/log.jsonl"),
        }

        -- Bench freshness
        local bf = io.open(AGENTS_DIR .. "/bench-results.json", "r")
        if bf then
            local b = cjson.decode(bf:read("*a")) or {}
            bf:close()
            local models = {}
            for _, r in ipairs(b.results or {}) do models[r.model or "?"] = (models[r.model or "?"] or 0) + 1 end
            local mlist = {}
            for m in pairs(models) do table.insert(mlist, m) end
            table.sort(mlist)
            out.agents.bench = {
                generated_at    = b.started_at,
                trials_per_cell = b.trials_per_cell,
                total_trials    = #(b.results or {}),
                models_present  = mlist,
                skipped_models  = b.skipped_models or {},
                model_created   = b.model_created or {},
            }
        end

        -- Routing freshness
        local rf = io.open(AGENTS_DIR .. "/routing.json", "r")
        if rf then
            local r = cjson.decode(rf:read("*a")) or {}
            rf:close()
            local rcount = 0
            for _ in pairs(r.routes or {}) do rcount = rcount + 1 end
            out.agents.routing = {
                generated_at  = r.generated_at,
                default_model = r.default_model,
                route_count   = rcount,
            }
        end

        -- omlx live probe (3s timeout)
        local http_ok, http = pcall(require, "resty.http")
        if http_ok then
            local omlx_url = os.getenv("OMLX_URL") or "http://host.docker.internal:8000"
            local omlx_key = os.getenv("OMLX_API_KEY") or ""
            local httpc = http.new()
            httpc:set_timeout(3000)
            local res, err = httpc:request_uri(omlx_url .. "/v1/models/status", {
                method = "GET", headers = { ["Authorization"] = "Bearer " .. omlx_key },
            })
            if res and res.status == 200 then
                local s = cjson.decode(res.body) or {}
                out.agents.omlx = {
                    reachable        = true,
                    loaded_count     = s.loaded_count,
                    model_count      = s.model_count,
                    current_model_gb = s.current_model_memory and (s.current_model_memory / (1024^3)) or 0,
                    max_model_gb     = s.max_model_memory     and (s.max_model_memory     / (1024^3)) or 0,
                }
            else
                out.agents.omlx = {
                    reachable = false,
                    error     = (res and ("HTTP " .. res.status)) or err or "unknown",
                }
            end
        else
            out.agents.omlx = { reachable = false, error = "lua-resty-http unavailable" }
        end
    end

    ngx.say(cjson.encode(out))
    return
end

-- /internal/admin/services — proxy to compose-ctl sidecar for stack control.
-- GET  /internal/admin/services                    → list+state of all services
-- POST /internal/admin/services/<name>/<action>    → start|stop|restart|recreate
-- The sidecar runs at compose-ctl:8090 inside the gateii Docker network and
-- holds the docker-socket mount; the proxy never talks to Docker directly.
if uri == "/internal/admin/services"
   or uri:sub(1, #"/internal/admin/services/") == "/internal/admin/services/" then
    local http = require "resty.http"
    local httpc = http.new()
    httpc:set_timeouts(2000, 2000, 30000)  -- connect/send/read

    local sub_path = uri:sub(#"/internal/admin/services" + 1)  -- "" or "/<name>/<action>"
    local target = "http://compose-ctl:8090/services" .. sub_path
    local body
    if method == "POST" then
        ngx.req.read_body()
        body = ngx.req.get_body_data() or ""
    end

    local res, err = httpc:request_uri(target, {
        method = method,
        body = body,
        headers = { ["Content-Type"] = "application/json" },
    })
    if not res then
        ngx.status = 502
        ngx.say(cjson.encode({error = "compose-ctl unreachable: " .. (err or "unknown"),
                              hint = "check that the gateii-compose-ctl container is running"}))
        return
    end
    ngx.status = res.status
    ngx.say(res.body or "")
    return
end

-- /internal/admin/git-tracking — read/write per-repo tracking config
-- GET returns the current config (empty object if no file), PUT writes it back
-- after schema validation. The file lives in the data bind mount and is also
-- read by scripts/git-tracking.sh in the git-tracking container.
local GIT_TRACKING_PATH = "/etc/nginx/data/git-tracking.json"

if uri == "/internal/admin/git-tracking" and method == "GET" then
    local f = io.open(GIT_TRACKING_PATH, "r")
    if not f then
        ngx.say('{"default_author":"","interval":300,"repos":[]}')
        return
    end
    ngx.say(f:read("*a"))
    f:close()
    return
end

if uri == "/internal/admin/git-tracking" and method == "PUT" then
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body or body == "" then
        ngx.status = 400
        ngx.say('{"error":"Empty body — POST the full config JSON"}')
        return
    end
    local data, decode_err = cjson.decode(body)
    if not data then
        ngx.status = 400
        ngx.say(cjson.encode({error = "Invalid JSON: " .. tostring(decode_err)}))
        return
    end
    -- Defensive path checks beyond schema.validate_git_tracking — block traversal
    if data.repos then
        for i, r in ipairs(data.repos) do
            if r.path then
                if r.path:sub(1, 1) ~= "/" then
                    ngx.status = 400
                    ngx.say(cjson.encode({error = "repos[" .. i .. "].path must be absolute (start with /)"}))
                    return
                end
                if r.path:find("%.%.") then
                    ngx.status = 400
                    ngx.say(cjson.encode({error = "repos[" .. i .. "].path contains '..' — not allowed"}))
                    return
                end
            end
        end
    end
    local ok, err = schema.validate_git_tracking(data)
    if not ok then
        ngx.status = 400
        ngx.say(cjson.encode({error = err}))
        return
    end
    local ok2, write_err = util.atomic_write(GIT_TRACKING_PATH, cjson.encode(data))
    if not ok2 then
        ngx.status = 500
        ngx.say(cjson.encode({error = write_err}))
        return
    end
    ngx.say(cjson.encode({ok = true, repos = #(data.repos or {})}))
    return
end

-- GET /internal/admin/agents — local omlx-agent state for the Console "Agents" tab
-- Reads files written by scripts/agent (mounted at /etc/nginx/data/agents):
--   active.json         currently-running agent (omitted if idle)
--   log.jsonl           append-only per-call history (last 50 returned)
--   routing.json        bench-picked model/max_tokens per task
--   bench-results.json  full per-trial bench data (used to build per-task × per-model matrix)
-- Plus a live call to omlx /v1/models/status for current load + RAM (graceful on omlx down).
local AGENTS_DIR = "/etc/nginx/data/agents"
if uri == "/internal/admin/agents" and method == "GET" then
    local out = { active = nil, recent = {}, routing = nil, bench = nil, omlx_status = nil }

    local af = io.open(AGENTS_DIR .. "/active.json", "r")
    if af then
        local content = af:read("*a"); af:close()
        out.active = cjson.decode(content)
    end

    -- Per-model usage stats aggregated from the FULL log.jsonl (not just last 50)
    -- so we capture lifetime efficiency per model.
    local usage = {}  -- model → {runs, passed, latency_sum, last_used_epoch, by_task={}}
    local lf = io.open(AGENTS_DIR .. "/log.jsonl", "r")
    if lf then
        local lines = {}
        for line in lf:lines() do
            if line ~= "" then table.insert(lines, line) end
        end
        lf:close()
        -- Aggregate usage from all lines
        for _, raw in ipairs(lines) do
            local rec = cjson.decode(raw)
            if rec and rec.model then
                local m = rec.model
                usage[m] = usage[m] or { runs=0, passed=0, latency_sum=0, last_used_at=nil }
                usage[m].runs = usage[m].runs + 1
                if rec.exit == 0 then usage[m].passed = usage[m].passed + 1 end
                usage[m].latency_sum = usage[m].latency_sum + (rec.latency_s or 0)
                -- ISO date sort works lex; keep latest
                if not usage[m].last_used_at or (rec.started_at and rec.started_at > usage[m].last_used_at) then
                    usage[m].last_used_at = rec.started_at
                end
            end
        end
        -- Recent (last 50) for the table
        local start_idx = math.max(1, #lines - 49)
        for i = start_idx, #lines do
            local rec = cjson.decode(lines[i])
            if rec then table.insert(out.recent, rec) end
        end
    end
    -- Convert to output shape (avg latency, pass rate)
    out.usage = {}
    for model, u in pairs(usage) do
        out.usage[model] = {
            runs        = u.runs,
            pass_rate   = u.runs > 0 and (u.passed / u.runs) or 0,
            latency_avg = u.runs > 0 and (u.latency_sum / u.runs) or 0,
            last_used_at = u.last_used_at,
        }
    end

    local rf = io.open(AGENTS_DIR .. "/routing.json", "r")
    if rf then
        local content = rf:read("*a"); rf:close()
        out.routing = cjson.decode(content)
    end

    -- Aggregate bench-results.json by (task, model) → pass-rate + p50 latency
    local bf = io.open(AGENTS_DIR .. "/bench-results.json", "r")
    if bf then
        local content = bf:read("*a"); bf:close()
        local b = cjson.decode(content)
        if b and b.results then
            local cells = {}  -- key = task .. "|" .. model
            local tasks_set = {}
            local models_set = {}
            for _, r in ipairs(b.results) do
                local k = (r.task or "?") .. "|" .. (r.model or "?")
                cells[k] = cells[k] or { runs = 0, passed = 0, lats = {} }
                cells[k].runs = cells[k].runs + 1
                if r.compliant then cells[k].passed = cells[k].passed + 1 end
                table.insert(cells[k].lats, r.latency_s or 0)
                tasks_set[r.task or "?"] = true
                models_set[r.model or "?"] = true
            end
            -- Compute median per cell
            local matrix = {}
            for k, c in pairs(cells) do
                table.sort(c.lats)
                local mid = math.ceil(#c.lats / 2)
                matrix[k] = {
                    runs       = c.runs,
                    passed     = c.passed,
                    pass_rate  = c.runs > 0 and (c.passed / c.runs) or 0,
                    latency_p50 = c.lats[mid] or 0,
                }
            end
            local tasks_list, models_list = {}, {}
            for t in pairs(tasks_set) do table.insert(tasks_list, t) end
            for m in pairs(models_set) do table.insert(models_list, m) end
            table.sort(tasks_list); table.sort(models_list)
            out.bench = {
                generated_at = b.started_at,
                trials_per_cell = b.trials_per_cell,
                tasks  = tasks_list,
                models = models_list,
                matrix = matrix,
            }
        end
    end

    -- Live: query omlx /v1/models/status (small file, fast local call)
    -- Failure is non-fatal — page still renders without live state.
    local http_ok, http = pcall(require, "resty.http")
    if http_ok then
        local omlx_url = os.getenv("OMLX_URL") or "http://host.docker.internal:8000"
        local omlx_key = os.getenv("OMLX_API_KEY") or ""
        local httpc = http.new()
        httpc:set_timeout(2000)
        local res, _ = httpc:request_uri(omlx_url .. "/v1/models/status", {
            method = "GET",
            headers = { ["Authorization"] = "Bearer " .. omlx_key },
        })
        if res and res.status == 200 then
            out.omlx_status = cjson.decode(res.body)
        end
    end

    ngx.header["Content-Type"] = "application/json"
    ngx.print(cjson.encode(out))
    return
end

-- POST /internal/admin/agents/bench — fire scripts/agent-bench in the
-- background via the compose-ctl sidecar (which has python + the writable
-- data/agents/ mount). Returns 202 immediately; progress is visible via
-- the existing Agents tab (active.json gets the "bench:" prefix).
if uri == "/internal/admin/agents/bench" and method == "POST" then
    ngx.req.read_body()
    local body = ngx.req.get_body_data() or "{}"
    local req_obj = cjson.decode(body) or {}
    local force = req_obj.force == true
    local http_ok, http = pcall(require, "resty.http")
    if not http_ok then
        ngx.status = 500
        ngx.say(cjson.encode({error = "lua-resty-http unavailable"}))
        return
    end
    local httpc = http.new()
    httpc:set_timeouts(1000, 1000, 5000)
    local res, err = httpc:request_uri("http://compose-ctl:8090/run-bench", {
        method  = "POST",
        headers = { ["Content-Type"] = "application/json" },
        body    = cjson.encode({force = force}),
    })
    if not res then
        ngx.status = 502
        ngx.say(cjson.encode({error = "compose-ctl unreachable: " .. tostring(err)}))
        return
    end
    ngx.status = res.status
    ngx.header["Content-Type"] = res.headers["Content-Type"] or "application/json"
    ngx.print(res.body)
    return
end

-- POST /internal/admin/models — load/unload an omlx model on demand
-- Body: {"action": "load"|"unload", "model": "<id>"}
-- Proxies to omlx /v1/models/<id>/(load|unload). Used by the Console
-- "Models" cards (per-model unload button); also handy from CLI.
if uri == "/internal/admin/models" and method == "POST" then
    ngx.req.read_body()
    local body = ngx.req.get_body_data() or "{}"
    local req_obj = cjson.decode(body) or {}
    local action  = req_obj.action
    local model   = req_obj.model
    if action ~= "load" and action ~= "unload" then
        ngx.status = 400
        ngx.say(cjson.encode({error = "action must be 'load' or 'unload'"}))
        return
    end
    if not model or model == "" then
        ngx.status = 400
        ngx.say(cjson.encode({error = "model id required"}))
        return
    end
    local http_ok, http = pcall(require, "resty.http")
    if not http_ok then
        ngx.status = 500
        ngx.say(cjson.encode({error = "lua-resty-http unavailable"}))
        return
    end
    local omlx_url = os.getenv("OMLX_URL") or "http://host.docker.internal:8000"
    local omlx_key = os.getenv("OMLX_API_KEY") or ""
    local httpc = http.new()
    httpc:set_timeout(10000)  -- load can be slow on cold start
    local res, req_err = httpc:request_uri(omlx_url .. "/v1/models/" .. model .. "/" .. action, {
        method  = "POST",
        headers = { ["Authorization"] = "Bearer " .. omlx_key },
    })
    if not res then
        ngx.status = 502
        ngx.say(cjson.encode({error = "omlx unreachable: " .. (req_err or "?")}))
        return
    end
    ngx.status = res.status
    ngx.header["Content-Type"] = res.headers["Content-Type"] or "application/json"
    ngx.print(res.body)
    return
end

ngx.status = 404
ngx.say('{"error":"Unknown admin endpoint — available: /internal/admin/{block,unblock,limit,status,'
    .. 'usage,keys,addkey,overview,providers,llm-prices,openrouter-models,health,git-tracking,services,diagnostics,bootstrap,agents}"}')
