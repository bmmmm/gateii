-- bootstrap.lua: HMAC-SHA256 challenge-response handshake for key provisioning.
--
-- Flow:
--   1. Admin calls create(...) → pending entry + (code, secret) returned once.
--   2. Client posts /internal/bootstrap/challenge {code}     → {nonce}
--   3. Client posts /internal/bootstrap/exchange  {code, nonce, proof} → {api_key, confirm_token}
--      (proof = HMAC_SHA256(secret, code || ":" || nonce), hex)
--   4. Client installs key, verifies via /health.
--   5. Client posts /internal/bootstrap/confirm   {confirm_token, status, proof}
--      (proof = HMAC_SHA256(secret, confirm_token || ":" || status), hex)
--      status = "installed" → key committed; status = "failed" → key revoked.
--   6. Sweeper (every 30s) revokes confirm-sessions that exceed TTL without confirm.
--
-- Storage:
--   bootstrap_pending[code]         → {user, provider, upstream_key, secret_hex,
--                                      expires_at, nonce?, nonce_expires?}
--   bootstrap_sessions[conf_token]  → {api_key, user, provider, upstream_key,
--                                      created_at, expires_at, secret_hex}

local cjson         = require "cjson.safe"
local sha256        = require "resty.sha256"
local resty_random  = require "resty.random"
local resty_string  = require "resty.string"
local bit           = require "bit"

local _M = {}

local KEYS_FILE            = "/etc/nginx/data/keys.json"
-- Bootstrap handshake tuning (override via env, see .env.example).
local CONFIRM_TTL_DEFAULT  = tonumber(os.getenv("BOOTSTRAP_CONFIRM_TTL"))  or 300   -- 5min confirm window
local PENDING_TTL_DEFAULT  = tonumber(os.getenv("BOOTSTRAP_PENDING_TTL"))  or 600   -- 10min bootstrap-code lifetime
local PENDING_TTL_MAX      = tonumber(os.getenv("BOOTSTRAP_PENDING_MAX"))  or 3600  -- 1h hard cap
local NONCE_TTL            = tonumber(os.getenv("BOOTSTRAP_NONCE_TTL"))    or 60    -- nonce window inside pending
local SWEEP_INTERVAL       = 30
local MAX_ITER_KEYS        = 1000

-- ---------------------------------------------------------------------------
-- Crypto primitives (RFC 2104 HMAC-SHA256, no native binding needed)
-- ---------------------------------------------------------------------------

local function hex_to_bin(hex)
    return (hex:gsub("..", function(h) return string.char(tonumber(h, 16) or 0) end))
end

local function hmac_sha256_bin(key, msg)
    local block_size = 64
    if #key > block_size then
        local sha = sha256:new()
        sha:update(key); key = sha:final()
    end
    if #key < block_size then
        key = key .. string.rep("\0", block_size - #key)
    end
    local o_pad, i_pad = {}, {}
    for i = 1, block_size do
        local b = key:byte(i)
        o_pad[i] = string.char(bit.bxor(b, 0x5c))
        i_pad[i] = string.char(bit.bxor(b, 0x36))
    end
    local inner = sha256:new()
    inner:update(table.concat(i_pad))
    inner:update(msg)
    local outer = sha256:new()
    outer:update(table.concat(o_pad))
    outer:update(inner:final())
    return outer:final()
end

local function hmac_sha256_hex(secret_hex, msg)
    return resty_string.to_hex(hmac_sha256_bin(hex_to_bin(secret_hex), msg))
end
_M._hmac_sha256_hex = hmac_sha256_hex  -- exported for tests

-- Constant-time byte-string equality to avoid timing-side-channel leaks
local function consttime_eq(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i)))
    end
    return diff == 0
end
_M._consttime_eq = consttime_eq

local function random_hex(n)
    local raw = resty_random.bytes(n, true)   -- true = cryptographically strong
    if not raw then
        -- Fall back to /dev/urandom via resty_random without strong flag
        raw = resty_random.bytes(n) or ""
    end
    return resty_string.to_hex(raw)
end

local function random_code()
    local raw = resty_random.bytes(16, true) or resty_random.bytes(16)
    local b64 = ngx.encode_base64(raw or "", true)
    b64 = b64:gsub("+", "-"):gsub("/", "_")
    return "btp_" .. b64
end

-- ---------------------------------------------------------------------------
-- Storage helpers
-- ---------------------------------------------------------------------------

local function pending_dict()  return ngx.shared.bootstrap_pending  end
local function sessions_dict() return ngx.shared.bootstrap_sessions end

local function get_json(dict, key)
    if not dict then return nil end
    local raw = dict:get(key)
    if not raw then return nil end
    return cjson.decode(raw)
end

local function set_json(dict, key, tbl, ttl)
    local encoded = cjson.encode(tbl)
    if not encoded then return nil, "encode_failed" end
    return dict:set(key, encoded, ttl or 0)
end

local function keys_read()
    local f = io.open(KEYS_FILE, "r")
    if not f then return {} end
    local raw = f:read("*a"); f:close()
    return cjson.decode(raw) or {}
end

-- Atomic write via temp + rename — survives process crashes mid-write
local function keys_write(keys)
    local encoded = cjson.encode(keys)
    if not encoded then return false, "encode_failed" end
    local tmp = KEYS_FILE .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false, "open_failed" end
    f:write(encoded); f:close()
    local ok, err = os.rename(tmp, KEYS_FILE)
    if not ok then return false, err or "rename_failed" end
    return true
end

local function json_resp(status, obj)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(obj))
    return ngx.exit(status)
end

-- Read + JSON-decode body
local function read_json_body()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body or body == "" then return nil, "missing body" end
    local obj, err = cjson.decode(body)
    if not obj then return nil, "invalid JSON: " .. tostring(err) end
    return obj
end

-- ---------------------------------------------------------------------------
-- Admin API (called from admin_api.lua under auth)
-- ---------------------------------------------------------------------------

-- Returns (result_table | nil, err_string?). On success, result contains
-- {code, secret, expires, ttl} — the secret is the one-time plaintext;
-- it is NEVER stored plain (only its hex form is kept for HMAC verify).
function _M.create(params)
    if type(params) ~= "table" then return nil, "params must be a table" end
    local user         = params.user
    local provider     = params.provider
    local upstream_key = params.upstream_key
    local ttl          = tonumber(params.ttl) or PENDING_TTL_DEFAULT
    if type(user) ~= "string" or user == ""                 then return nil, "user required"         end
    if type(provider) ~= "string" or provider == ""         then return nil, "provider required"     end
    if type(upstream_key) ~= "string" or upstream_key == "" then return nil, "upstream_key required" end
    if ttl < 30 or ttl > PENDING_TTL_MAX                    then return nil, "ttl out of range (30..3600)" end

    local code   = random_code()
    local secret = random_hex(32)   -- 32-byte HMAC key (64 hex chars)
    local now    = ngx.time()
    local entry = {
        user         = user,
        provider     = provider,
        upstream_key = upstream_key,
        secret_hex   = secret,
        created_at   = now,
        expires_at   = now + ttl,
    }
    local ok, err = set_json(pending_dict(), code, entry, ttl)
    if not ok then
        ngx.log(ngx.ERR, "bootstrap.create: dict write failed — ", err)
        return nil, "shared_dict_full"
    end
    return {
        code    = code,
        secret  = secret,
        expires = os.date("!%Y-%m-%dT%H:%M:%SZ", now + ttl),
        ttl     = ttl,
    }
end

function _M.list()
    local now = ngx.time()
    local pending, sessions = {}, {}
    local pd, sd = pending_dict(), sessions_dict()
    if pd then
        for _, code in ipairs(pd:get_keys(MAX_ITER_KEYS)) do
            local entry = get_json(pd, code)
            if entry then
                pending[#pending + 1] = {
                    code     = code,
                    user     = entry.user,
                    provider = entry.provider,
                    ttl      = math.max(0, (entry.expires_at or now) - now),
                }
            end
        end
    end
    if sd then
        for _, ct in ipairs(sd:get_keys(MAX_ITER_KEYS)) do
            local entry = get_json(sd, ct)
            if entry then
                sessions[#sessions + 1] = {
                    confirm_token = ct,
                    user          = entry.user,
                    provider      = entry.provider,
                    ttl           = math.max(0, (entry.expires_at or now) - now),
                }
            end
        end
    end
    return { pending = pending, sessions = sessions }
end

function _M.revoke_code(code)
    if type(code) ~= "string" or code == "" then return false, "code required" end
    local pd = pending_dict()
    if not pd then return false, "dict_missing" end
    if not pd:get(code) then return false, "not_found" end
    pd:delete(code)
    return true
end

-- ---------------------------------------------------------------------------
-- Client-facing handlers — bound in nginx.conf under /internal/bootstrap/*
-- ---------------------------------------------------------------------------

function _M.handle_challenge()
    if ngx.req.get_method() ~= "POST" then return json_resp(405, { error = "POST only" }) end
    local body, berr = read_json_body()
    if not body then return json_resp(400, { error = berr }) end

    local code = body.code
    if type(code) ~= "string" or code == "" then
        return json_resp(400, { error = "missing code" })
    end
    local entry = get_json(pending_dict(), code)
    if not entry then
        -- Uniform error to avoid code-enumeration oracle
        return json_resp(404, { error = "unknown or expired bootstrap code" })
    end
    -- Generate fresh nonce; overwrites any previous nonce for this code
    local nonce = random_hex(16)  -- 128 bits hex
    entry.nonce = nonce
    entry.nonce_expires = ngx.time() + NONCE_TTL
    local ttl_left = math.max(10, (entry.expires_at or 0) - ngx.time())
    set_json(pending_dict(), code, entry, ttl_left)

    return json_resp(200, { nonce = nonce, expires_in = NONCE_TTL })
end

function _M.handle_exchange()
    if ngx.req.get_method() ~= "POST" then return json_resp(405, { error = "POST only" }) end
    local body, berr = read_json_body()
    if not body then return json_resp(400, { error = berr }) end

    local code    = body.code
    local nonce   = body.nonce
    local proof   = body.proof
    if type(code) ~= "string"  or code == ""  then return json_resp(400, { error = "missing code"  }) end
    if type(nonce) ~= "string" or nonce == "" then return json_resp(400, { error = "missing nonce" }) end
    if type(proof) ~= "string" or proof == "" then return json_resp(400, { error = "missing proof" }) end

    local entry = get_json(pending_dict(), code)
    if not entry then return json_resp(404, { error = "unknown or expired bootstrap code" }) end
    if not entry.nonce or entry.nonce ~= nonce then
        return json_resp(400, { error = "nonce mismatch — request a fresh /challenge" })
    end
    if (entry.nonce_expires or 0) < ngx.time() then
        return json_resp(400, { error = "nonce expired — request a fresh /challenge" })
    end

    local expected = hmac_sha256_hex(entry.secret_hex, code .. ":" .. nonce)
    if not consttime_eq(expected, proof) then
        return json_resp(401, { error = "proof verification failed" })
    end

    -- Atomic: issue key, persist keys.json, drop pending, open confirm session
    local api_key = "sk-proxy-" .. random_hex(16)   -- 32 hex chars
    local now     = ngx.time()
    local keys    = keys_read()
    keys[api_key] = {
        user          = entry.user,
        provider      = entry.provider,
        upstream_key  = entry.upstream_key,
        created_at    = os.date("!%Y-%m-%dT%H:%M:%SZ", now),
        bootstrap_code = code,
    }
    local wok, werr = keys_write(keys)
    if not wok then
        ngx.log(ngx.ERR, "bootstrap.exchange: keys_write failed — ", werr)
        return json_resp(500, { error = "failed to persist key" })
    end

    local confirm_token = random_hex(16)
    local session = {
        api_key      = api_key,
        user         = entry.user,
        provider     = entry.provider,
        upstream_key = entry.upstream_key,
        created_at   = now,
        expires_at   = now + CONFIRM_TTL_DEFAULT,
        secret_hex   = entry.secret_hex,
    }
    local sok, serr = set_json(sessions_dict(), confirm_token, session, CONFIRM_TTL_DEFAULT)
    if not sok then
        -- Rollback: drop the just-issued key
        keys[api_key] = nil; keys_write(keys)
        ngx.log(ngx.ERR, "bootstrap.exchange: sessions dict write failed — ", serr)
        return json_resp(500, { error = "failed to open confirm session" })
    end

    -- Consume the one-time code
    pending_dict():delete(code)
    -- Invalidate any stale auth_cache for this new key (defensive)
    if ngx.shared.auth_cache then ngx.shared.auth_cache:delete(api_key) end

    ngx.log(ngx.NOTICE, "bootstrap: issued key for user=", entry.user,
            " provider=", entry.provider, " code=", code)

    return json_resp(200, {
        api_key       = api_key,
        user          = entry.user,
        provider      = entry.provider,
        confirm_token = confirm_token,
        confirm_ttl   = CONFIRM_TTL_DEFAULT,
    })
end

function _M.handle_confirm()
    if ngx.req.get_method() ~= "POST" then return json_resp(405, { error = "POST only" }) end
    local body, berr = read_json_body()
    if not body then return json_resp(400, { error = berr }) end

    local ct     = body.confirm_token
    local status = body.status
    local proof  = body.proof
    if type(ct) ~= "string"     or ct == ""     then return json_resp(400, { error = "missing confirm_token" }) end
    if type(status) ~= "string" or status == "" then return json_resp(400, { error = "missing status"        }) end
    if type(proof) ~= "string"  or proof == ""  then return json_resp(400, { error = "missing proof"         }) end
    if status ~= "installed" and status ~= "failed" then
        return json_resp(400, { error = "status must be 'installed' or 'failed'" })
    end

    local session = get_json(sessions_dict(), ct)
    if not session then return json_resp(404, { error = "unknown or expired confirm_token" }) end
    local expected = hmac_sha256_hex(session.secret_hex, ct .. ":" .. status)
    if not consttime_eq(expected, proof) then
        return json_resp(401, { error = "proof verification failed" })
    end

    if status == "installed" then
        -- Commit: drop the confirm session; key stays in keys.json
        sessions_dict():delete(ct)
        ngx.log(ngx.NOTICE, "bootstrap: confirm committed user=", session.user,
                " provider=", session.provider)
        return json_resp(200, { status = "committed" })
    else
        -- Rollback: remove the issued key from keys.json + auth_cache
        local keys = keys_read()
        keys[session.api_key] = nil
        keys_write(keys)
        if ngx.shared.auth_cache then ngx.shared.auth_cache:delete(session.api_key) end
        sessions_dict():delete(ct)
        ngx.log(ngx.NOTICE, "bootstrap: confirm failed → revoked key user=", session.user)
        return json_resp(200, { status = "revoked" })
    end
end

-- ---------------------------------------------------------------------------
-- Sweeper: revoke confirm sessions whose TTL lapsed without confirm
-- ---------------------------------------------------------------------------

function _M.sweep()
    local sd = sessions_dict()
    if not sd then return 0 end
    local now = ngx.time()
    local revoked = 0
    for _, ct in ipairs(sd:get_keys(MAX_ITER_KEYS)) do
        local entry = get_json(sd, ct)
        -- Explicit expiry check (shared_dict TTL usually removes first, but we check
        -- defensively — an entry may linger if TTL lookup is racy).
        if entry and (entry.expires_at or 0) < now then
            local keys = keys_read()
            if keys[entry.api_key] then
                keys[entry.api_key] = nil
                keys_write(keys)
                if ngx.shared.auth_cache then
                    ngx.shared.auth_cache:delete(entry.api_key)
                end
                revoked = revoked + 1
                ngx.log(ngx.NOTICE, "bootstrap.sweep: revoked un-confirmed key user=",
                        entry.user, " provider=", entry.provider)
            end
            sd:delete(ct)
        end
    end
    return revoked
end

local function sweep_timer_cb(premature)
    if premature then return end
    local ok, err = pcall(_M.sweep)
    if not ok then ngx.log(ngx.ERR, "bootstrap.sweep crashed: ", err) end
    local tok, terr = ngx.timer.at(SWEEP_INTERVAL, sweep_timer_cb)
    if not tok then ngx.log(ngx.ERR, "bootstrap: re-arming sweep timer failed: ", terr) end
end

function _M.start_sweeper()
    if ngx.worker.id() ~= 0 then return end   -- only worker 0 sweeps
    local ok, err = ngx.timer.at(SWEEP_INTERVAL, sweep_timer_cb)
    if not ok then ngx.log(ngx.ERR, "bootstrap: sweep timer init failed: ", err) end
end

-- ---------------------------------------------------------------------------
-- Router — single content_by_lua entry point for /internal/bootstrap/*
-- ---------------------------------------------------------------------------

function _M.route()
    local uri = ngx.var.uri
    if     uri == "/internal/bootstrap/challenge" then return _M.handle_challenge()
    elseif uri == "/internal/bootstrap/exchange"  then return _M.handle_exchange()
    elseif uri == "/internal/bootstrap/confirm"   then return _M.handle_confirm()
    else return json_resp(404, { error = "unknown bootstrap endpoint" }) end
end

return _M
