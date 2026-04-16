-- admin_api.lua: internal admin endpoints for blocking/unblocking
local cjson = require "cjson.safe"
local blocking_dict = ngx.shared.blocking
local counters = ngx.shared.counters

local method = ngx.req.get_method()
local uri = ngx.var.uri

ngx.header["Content-Type"] = "application/json"

-- Defense-in-depth auth: require X-Admin-Token header when ADMIN_TOKEN env is set.
-- Protects against lateral movement from a compromised container on the Docker network;
-- the IP allow-list in nginx.conf alone trusts every sidecar.
local ADMIN_TOKEN = os.getenv("ADMIN_TOKEN") or ""
if ADMIN_TOKEN ~= "" then
    local supplied = ngx.var.http_x_admin_token or ""
    if supplied ~= ADMIN_TOKEN then
        ngx.status = 401
        ngx.say('{"error":"Missing or invalid X-Admin-Token header"}')
        return ngx.exit(401)
    end
end

local LIMITS_FILE = "/etc/nginx/data/limits.json"

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
    local keys = blocking_dict:get_keys(0)
    for _, key in ipairs(keys) do
        if key:sub(1, 7) == "limits|" then
            local u = key:sub(8)
            local raw = blocking_dict:get(key)
            if raw then all[u] = cjson.decode(raw) end
        end
    end
    local encoded = cjson.encode(all)
    if not encoded then
        ngx.log(ngx.ERR, "save_limits: cjson.encode failed")
        return
    end
    local tmp = LIMITS_FILE .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then
        ngx.log(ngx.ERR, "save_limits: cannot open ", tmp, " for writing — limits not persisted to disk")
        return
    end
    f:write(encoded)
    f:close()
    local ok, err = os.rename(tmp, LIMITS_FILE)
    if not ok then
        ngx.log(ngx.ERR, "save_limits: rename failed: ", err)
    end
end

-- POST /internal/admin/block?user=X&ttl=86400
if uri == "/internal/admin/block" and method == "POST" then
    local args = ngx.req.get_uri_args()
    local user = require_user(args); if not user then return end
    local ttl = tonumber(args.ttl) or 86400
    blocking_dict:set("blocked|" .. user, "manual", ttl)
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
    if limits.requests_per_day ~= nil and not is_pos_int(limits.requests_per_day) then
        ngx.status = 400
        ngx.say('{"error":"requests_per_day must be a positive integer"}')
        return
    end
    if limits.tokens_per_day == nil and limits.requests_per_day == nil then
        ngx.status = 400
        ngx.say('{"error":"Provide at least one of: tokens_per_day, requests_per_day"}')
        return
    end
    blocking_dict:set("limits|" .. user, cjson.encode(limits))
    save_limits()
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
    for key, user in pairs(parsed) do
        keys_data[#keys_data + 1] = { key = key:sub(1, 12) .. "..." .. key:sub(-6), user = user }
    end
    ngx.say(cjson.encode({ keys = keys_data, count = #keys_data }))
    return
end

-- GET /internal/admin/overview — combined status for console
if uri == "/internal/admin/overview" and method == "GET" then
    -- Proxy mode
    local mode = os.getenv("PROXY_MODE") or "passthrough"
    local passthrough_user = os.getenv("PASSTHROUGH_USER") or ""

    -- Key count
    local key_count = 0
    for _ in pairs(read_keys_file()) do key_count = key_count + 1 end

    -- Blocked count
    local blocked_count = 0
    local block_keys = blocking_dict:get_keys(0) or {}
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

    -- Collect all day|*|today|* keys from counters
    local all_keys = counters:get_keys(0)
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
    local block_keys = blocking_dict:get_keys(0)
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

    if #result == 0 then
        ngx.say('[]')
    else
        ngx.say(cjson.encode(result))
    end
    return
end

-- POST /internal/admin/addkey?user=X  body: {"key":"sk-proxy-..."}
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
    local key = ""
    if body then
        local obj = cjson.decode(body)
        if obj then key = tostring(obj.key or "") end
    end
    if key == "" then
        ngx.status = 400
        ngx.say('{"error":"Missing key — send JSON body: {\"key\":\"sk-proxy-...\"}"}')
        return
    end
    -- Validate key format
    if not key:match("^sk%-proxy%-[a-f0-9]+$") and not key:match("^sk%-[a-zA-Z0-9_%-]+$") then
        ngx.status = 400
        ngx.say('{"error":"Invalid key format"}')
        return
    end
    -- Read current keys, add, write back
    local keys_data = read_keys_file()
    keys_data[key] = user
    local encoded = cjson.encode(keys_data)
    if not encoded then
        ngx.status = 500
        ngx.say('{"error":"Failed to encode keys"}')
        return
    end
    local tmp = "/etc/nginx/data/keys.json.tmp"
    local wf = io.open(tmp, "w")
    if not wf then
        ngx.status = 500
        ngx.say('{"error":"Cannot write keys.json"}')
        return
    end
    wf:write(encoded)
    wf:close()
    local rok, rerr = os.rename(tmp, "/etc/nginx/data/keys.json")
    if not rok then
        ngx.log(ngx.ERR, "addkey: rename failed: ", rerr)
        ngx.status = 500
        ngx.say('{"error":"Failed to persist keys.json — check server logs"}')
        return
    end
    -- Clear any negative cache entry so the new key is usable immediately
    ngx.shared.auth_cache:delete(key)
    ngx.say(cjson.encode({ok = true, user = user}))
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
        httpc:set_timeouts(1500, 1500, 3000)
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
    for _, key in ipairs(counters:get_keys(0)) do
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

ngx.status = 404
ngx.say('{"error":"Unknown admin endpoint — available: /internal/admin/{block,unblock,limit,status,usage,keys,addkey,overview,providers,llm-prices,openrouter-models,health}"}')
