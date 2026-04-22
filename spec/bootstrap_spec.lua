-- spec/bootstrap_spec.lua
-- Unit tests for pure-Lua helpers inside bootstrap.lua that don't require the
-- OpenResty runtime. Full protocol coverage lives in scripts/smoke-test.sh
-- where an actual proxy process handles shared dicts + nginx timers.
--
-- Run with: busted spec/bootstrap_spec.lua

package.path = package.path .. ";config/openresty/lua/?.lua"

-- Minimal ngx/resty stubs so bootstrap.lua can be required.
_G.ngx = {
    shared = {},
    time   = function() return 1700000000 end,
    now    = function() return 1700000000 end,
    log    = function() end,
    ERR    = 1, WARN = 2, NOTICE = 3, INFO = 4,
    worker = { id = function() return 0 end, pid = function() return 1 end },
    encode_base64 = function(s) return (s or ""):gsub("(.)", function(c)
        return string.format("%02x", c:byte())  -- not real base64, but deterministic
    end) end,
    timer  = { at = function() return true end, every = function() return true end },
    req    = { get_method = function() return "POST" end },
}

-- Stub resty.sha256 with a minimal identity digest for stub-ability checks
-- (real crypto is covered by smoke-test against OpenResty's implementation).
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
