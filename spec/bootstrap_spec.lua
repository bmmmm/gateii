-- spec/bootstrap_spec.lua
-- Unit tests for bootstrap.lua: crypto helpers + full state-machine
-- (create, challenge, exchange, confirm).  Shared dicts and keys.json I/O
-- are replaced by in-memory stubs so no OpenResty runtime is required.
--
-- Run with: busted spec/bootstrap_spec.lua

package.path = package.path .. ";config/openresty/lua/?.lua"

-- ---------------------------------------------------------------------------
-- Shared-dict stub factory
-- ---------------------------------------------------------------------------

local function make_dict()
    local store, ttls = {}, {}
    return {
        get      = function(_, k) return store[k] end,
        set      = function(_, k, v, ttl) store[k] = v; ttls[k] = ttl; return true end,
        delete   = function(_, k) store[k] = nil end,
        -- add: succeeds only if the key is absent (atomic claim primitive).
        add      = function(_, k, v, ttl)
            if store[k] ~= nil then return false, "exists" end
            store[k] = v; ttls[k] = ttl; return true
        end,
        -- incr: bumps an existing number; seeds with init when absent.
        incr     = function(_, k, n, init, init_ttl)
            if store[k] == nil then
                if init == nil then return nil, "not found" end
                store[k] = init + n; ttls[k] = init_ttl; return store[k]
            end
            store[k] = store[k] + n; return store[k]
        end,
        get_keys = function(_, n)
            local ks = {}
            for k in pairs(store) do ks[#ks+1] = k end
            return ks
        end,
        free_space = function() return 1000000 end,
    }
end

-- ---------------------------------------------------------------------------
-- Clock stub (mutable so tests can advance time)
-- ---------------------------------------------------------------------------

local _now = 1700000000
local function set_time(t) _now = t end

-- ---------------------------------------------------------------------------
-- Minimal ngx / resty stubs
-- ---------------------------------------------------------------------------

local _say_buf = {}

_G.ngx = {
    shared = {
        bootstrap_pending  = make_dict(),
        bootstrap_sessions = make_dict(),
        auth_cache         = make_dict(),
        -- proxy_config.update_keys serializes keys.json writes via this dict
        -- (keys_write_lock + keys_gen) — bootstrap now routes writes through it.
        blocking           = make_dict(),
    },
    time   = function() return _now end,
    now    = function() return _now end,
    sleep  = function() end,
    log    = function() end,
    ERR    = 1, WARN = 2, NOTICE = 3, INFO = 4,
    worker = { id = function() return 0 end, pid = function() return 1 end },
    encode_base64 = function(s)
        -- Deterministic but not real base64 — good enough for code-uniqueness checks.
        return (s or ""):gsub("(.)", function(c)
            return string.format("%02x", c:byte())
        end)
    end,
    timer  = { at = function() return true end, every = function() return true end },
    -- Request stubs (overridable per-test via the helpers below)
    req    = {
        get_method    = function() return "POST" end,
        read_body     = function() end,
        get_body_data = function() return nil end,
    },
    status  = 200,
    header  = {},
    say     = function(s) _say_buf[#_say_buf+1] = s end,
    exit    = function(code) error("ngx.exit:" .. tostring(code)) end,
}

-- Stub resty.sha256 with a minimal identity digest.
-- Real HMAC correctness is verified in smoke-test against the live OpenResty binary.
package.loaded["resty.sha256"] = {
    new = function()
        local buf = {}
        return {
            update = function(self, s) buf[#buf+1] = s; return self end,
            final  = function(self) return table.concat(buf) end,
        }
    end,
}
package.loaded["resty.random"] = {
    bytes = function(n) return string.rep("\1", n) end,
}
package.loaded["resty.string"] = {
    to_hex = function(s)
        return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    end,
}

-- ---------------------------------------------------------------------------
-- keys.json stub: route io.open for the known path to an in-memory table
-- ---------------------------------------------------------------------------

local _keys_store = {}
local _real_io_open = io.open

local KEYS_PATH     = "/etc/nginx/data/keys.json"
local KEYS_PATH_TMP = KEYS_PATH .. ".tmp"

local function install_keys_stub()
    local cjson = require "cjson.safe"
    local _pending_write = nil

    io.open = function(path, mode)
        if path == KEYS_PATH then
            if mode == "r" then
                local encoded = cjson.encode(_keys_store) or "{}"
                local pos = 1
                return {
                    read  = function(_, fmt)
                        if fmt == "*a" then
                            local out = encoded:sub(pos)
                            pos = #encoded + 1
                            return out
                        end
                    end,
                    close = function() end,
                }
            end
        elseif path == KEYS_PATH_TMP then
            if mode == "w" then
                local buf = {}
                return {
                    -- Return truthy like a real file handle: util.atomic_write
                    -- checks `f:write(...)`'s return value and aborts on falsy.
                    write = function(_, s) buf[#buf+1] = s; return true end,
                    -- Return truthy: util.atomic_write also checks f:close()'s return
                    -- (a close-flush failure must abort the rename), mirroring a real handle.
                    close = function()
                        _pending_write = table.concat(buf)
                        return true
                    end,
                }
            end
        end
        return _real_io_open(path, mode)
    end

    local _real_os_rename = os.rename
    os.rename = function(src, dst)
        if src == KEYS_PATH_TMP and dst == KEYS_PATH then
            if _pending_write then
                local decoded = cjson.decode(_pending_write)
                if decoded then
                    -- Clear then repopulate so identity is preserved
                    for k in pairs(_keys_store) do _keys_store[k] = nil end
                    for k, v in pairs(decoded) do _keys_store[k] = v end
                end
                _pending_write = nil
            end
            return true
        end
        return _real_os_rename(src, dst)
    end
end

local function reset_stubs()
    -- Reset shared dicts
    _G.ngx.shared.bootstrap_pending  = make_dict()
    _G.ngx.shared.bootstrap_sessions = make_dict()
    _G.ngx.shared.auth_cache         = make_dict()
    _G.ngx.shared.blocking           = make_dict()
    -- Reset keys store
    for k in pairs(_keys_store) do _keys_store[k] = nil end
    -- Reset say buffer
    for i in ipairs(_say_buf) do _say_buf[i] = nil end
    -- Reset clock
    set_time(1700000000)
    -- Reset HTTP state
    _G.ngx.status = 200
    _G.ngx.header = {}
    _G.ngx.req.get_method    = function() return "POST" end
    _G.ngx.req.read_body     = function() end
    _G.ngx.req.get_body_data = function() return nil end
    -- Force fresh module load
    package.loaded["bootstrap"] = nil
end

-- Install the keys.json stub once (before any require)
install_keys_stub()

-- ---------------------------------------------------------------------------
-- Helper: run a handler and capture the status + first ngx.say payload.
-- bootstrap handlers call ngx.exit() which we turn into an error; we catch
-- it and return the status code + accumulated say output.
-- ---------------------------------------------------------------------------

local cjson = require "cjson.safe"

local function run_handler(fn)
    _say_buf = {}
    _G.ngx.status = 200
    local ok, err = pcall(fn)
    local code = _G.ngx.status
    if not ok then
        -- Extract code from "ngx.exit:NNN" errors
        local n = tostring(err):match("ngx%.exit:(%d+)")
        if n then code = tonumber(n) end
    end
    local body = _say_buf[1] and cjson.decode(_say_buf[1])
    return code, body
end

-- Helper: set the request body for handlers that call read_json_body()
local function set_body(tbl)
    local encoded = cjson.encode(tbl)
    _G.ngx.req.get_body_data = function() return encoded end
end

local bootstrap = require "bootstrap"

describe("bootstrap._consttime_eq", function()
    it("true for equal strings", function()
        assert.is_true(bootstrap._consttime_eq("abc", "abc"))
    end)
    it("false for different content, same length", function()
        assert.is_false(bootstrap._consttime_eq("abc", "abd"))
    end)
    it("false for different lengths", function()
        assert.is_false(bootstrap._consttime_eq("abc", "abcd"))
    end)
    it("false for non-string inputs", function()
        assert.is_false(bootstrap._consttime_eq(nil, "abc"))
        assert.is_false(bootstrap._consttime_eq("abc", 123))
        assert.is_false(bootstrap._consttime_eq({}, {}))
    end)
    it("handles empty strings consistently", function()
        assert.is_true(bootstrap._consttime_eq("", ""))
        assert.is_false(bootstrap._consttime_eq("", "a"))
    end)
end)

describe("bootstrap._hmac_sha256_hex", function()
    it("is deterministic for a given (secret, message) pair", function()
        local a = bootstrap._hmac_sha256_hex("deadbeef", "hello")
        local b = bootstrap._hmac_sha256_hex("deadbeef", "hello")
        assert.equals(a, b)
    end)
    it("changes when message changes", function()
        local a = bootstrap._hmac_sha256_hex("deadbeef", "hello")
        local b = bootstrap._hmac_sha256_hex("deadbeef", "world")
        assert.are_not.equal(a, b)
    end)
    it("changes when secret changes", function()
        local a = bootstrap._hmac_sha256_hex("aa", "m")
        local b = bootstrap._hmac_sha256_hex("bb", "m")
        assert.are_not.equal(a, b)
    end)
    it("output is hex-only", function()
        local h = bootstrap._hmac_sha256_hex("cafe", "msg")
        assert.matches("^[0-9a-f]+$", h)
    end)
end)

-- ---------------------------------------------------------------------------
-- State-machine tests (require stubs installed above)
-- ---------------------------------------------------------------------------

describe("bootstrap.create", function()
    before_each(function() reset_stubs(); bootstrap = require "bootstrap" end)

    it("returns code, secret, expires, ttl on valid params", function()
        local r, err = bootstrap.create({ user="alice", provider="anthropic", upstream_key="sk-x" })
        assert.is_nil(err)
        assert.matches("^btp_", r.code)
        assert.matches("^[0-9a-f]+$", r.secret)
        assert.matches("%d+-%d+-%d+T", r.expires)
        assert.equals(600, r.ttl)
    end)

    it("stores entry in bootstrap_pending dict", function()
        local r = bootstrap.create({ user="alice", provider="anthropic", upstream_key="sk-x" })
        local raw = _G.ngx.shared.bootstrap_pending:get(r.code)
        assert.is_string(raw)
        local entry = require("cjson.safe").decode(raw)
        assert.equals("alice", entry.user)
        assert.equals("anthropic", entry.provider)
    end)

    it("fails without user", function()
        local r, err = bootstrap.create({ provider="anthropic", upstream_key="sk-x" })
        assert.is_nil(r)
        assert.matches("user", err)
    end)

    it("fails without provider", function()
        local r, err = bootstrap.create({ user="alice", upstream_key="sk-x" })
        assert.is_nil(r)
        assert.matches("provider", err)
    end)

    it("fails without upstream_key", function()
        local r, err = bootstrap.create({ user="alice", provider="anthropic" })
        assert.is_nil(r)
        assert.matches("upstream_key", err)
    end)

    it("rejects ttl below 30", function()
        local r, err = bootstrap.create({ user="alice", provider="anthropic", upstream_key="sk-x", ttl=10 })
        assert.is_nil(r)
        assert.matches("ttl", err)
    end)

    it("rejects ttl above 3600", function()
        local r, err = bootstrap.create({ user="alice", provider="anthropic", upstream_key="sk-x", ttl=9999 })
        assert.is_nil(r)
        assert.matches("ttl", err)
    end)
end)

describe("bootstrap challenge → exchange → confirm flow", function()
    local SECRET, CODE, NONCE, API_KEY, CONFIRM_TOKEN

    before_each(function()
        reset_stubs()
        bootstrap = require "bootstrap"
        local r = bootstrap.create({ user="bob", provider="anthropic", upstream_key="sk-upstream" })
        CODE   = r.code
        SECRET = r.secret
    end)

    local function do_challenge()
        set_body({ code = CODE })
        local code, body = run_handler(function() bootstrap.handle_challenge() end)
        assert.equals(200, code)
        NONCE = body.nonce
        assert.is_string(NONCE)
    end

    local function do_exchange()
        local proof = bootstrap._hmac_sha256_hex(SECRET, CODE .. ":" .. NONCE)
        set_body({ code = CODE, nonce = NONCE, proof = proof })
        local code, body = run_handler(function() bootstrap.handle_exchange() end)
        assert.equals(200, code)
        API_KEY       = body.api_key
        CONFIRM_TOKEN = body.confirm_token
        assert.matches("^sk%-proxy%-", API_KEY)
        assert.is_string(CONFIRM_TOKEN)
    end

    it("challenge issues a nonce", function()
        do_challenge()
        assert.matches("^[0-9a-f]+$", NONCE)
    end)

    it("challenge fails for unknown code", function()
        set_body({ code = "btp_doesnotexist" })
        local code = run_handler(function() bootstrap.handle_challenge() end)
        assert.equals(404, code)
    end)

    it("exchange with correct proof issues api_key and confirm_token", function()
        do_challenge()
        do_exchange()
        -- Code must be consumed (one-time)
        assert.is_nil(_G.ngx.shared.bootstrap_pending:get(CODE))
        -- Key must be in keys_store
        assert.is_not_nil(_keys_store[API_KEY])
        assert.equals("bob", _keys_store[API_KEY].user)
    end)

    it("exchange with wrong proof returns 401", function()
        do_challenge()
        set_body({ code = CODE, nonce = NONCE, proof = "badc0de0badc0de0badc0de0badc0de0badc0de0badc0de0badc0de0badc0de0" })
        local code = run_handler(function() bootstrap.handle_exchange() end)
        assert.equals(401, code)
    end)

    it("exchange with wrong nonce returns 400", function()
        do_challenge()
        local proof = bootstrap._hmac_sha256_hex(SECRET, CODE .. ":wrongnonce")
        set_body({ code = CODE, nonce = "wrongnonce", proof = proof })
        local code = run_handler(function() bootstrap.handle_exchange() end)
        assert.equals(400, code)
    end)

    it("confirm status=installed commits the key", function()
        do_challenge(); do_exchange()
        local proof = bootstrap._hmac_sha256_hex(SECRET, CONFIRM_TOKEN .. ":installed")
        set_body({ confirm_token = CONFIRM_TOKEN, status = "installed", proof = proof })
        local code, body = run_handler(function() bootstrap.handle_confirm() end)
        assert.equals(200, code)
        assert.equals("committed", body.status)
        -- Session cleaned up
        assert.is_nil(_G.ngx.shared.bootstrap_sessions:get(CONFIRM_TOKEN))
        -- Key still in keys_store
        assert.is_not_nil(_keys_store[API_KEY])
    end)

    it("confirm status=failed revokes the key", function()
        do_challenge(); do_exchange()
        local proof = bootstrap._hmac_sha256_hex(SECRET, CONFIRM_TOKEN .. ":failed")
        set_body({ confirm_token = CONFIRM_TOKEN, status = "failed", proof = proof })
        local code, body = run_handler(function() bootstrap.handle_confirm() end)
        assert.equals(200, code)
        assert.equals("revoked", body.status)
        -- Key must be removed
        assert.is_nil(_keys_store[API_KEY])
    end)

    it("confirm with wrong proof returns 401", function()
        do_challenge(); do_exchange()
        set_body({ confirm_token = CONFIRM_TOKEN, status = "installed",
                   proof = "badc0de0badc0de0badc0de0badc0de0badc0de0badc0de0badc0de0badc0de0" })
        local code = run_handler(function() bootstrap.handle_confirm() end)
        assert.equals(401, code)
    end)

    it("confirm with unknown token returns 404", function()
        set_body({ confirm_token = "deadbeefdeadbeef", status = "installed", proof = "aa" })
        local code = run_handler(function() bootstrap.handle_confirm() end)
        assert.equals(404, code)
    end)
end)
