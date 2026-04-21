-- Tests for circuit breaker state machine.
-- Run with: busted spec/circuit_breaker_spec.lua

-- Stub ngx with a minimal shared dict + time mock
local _now = 1700000000
local _dict_data = {}
_G.ngx = {
    shared = {
        counters = {
            get = function(_, k) return _dict_data[k] end,
            set = function(_, k, v, _) _dict_data[k] = v; return true end,
        },
    },
    time = function() return _now end,
    log  = function() end,
    ERR  = 1, WARN = 2, NOTICE = 3, INFO = 4,
}

package.path = package.path .. ";config/openresty/lua/?.lua"

local function reset_state()
    for k in pairs(_dict_data) do _dict_data[k] = nil end
    _now = 1700000000
    package.loaded.circuit_breaker = nil
end

describe("circuit_breaker", function()
    local cb
    before_each(function()
        reset_state()
        cb = require "circuit_breaker"
    end)

    it("allows requests when closed", function()
        local ok, _ = cb.allow_request("anthropic")
        assert.is_true(ok)
    end)

    it("opens after threshold consecutive failures", function()
        for i = 1, cb._FAILURE_THRESHOLD do
            cb.record("anthropic", 500, nil)
        end
        local ok, reason = cb.allow_request("anthropic")
        assert.is_false(ok)
        assert.equals("circuit_open", reason)
    end)

    it("does not open on 4xx failures", function()
        for i = 1, cb._FAILURE_THRESHOLD + 2 do
            cb.record("anthropic", 429, nil)
        end
        local ok = cb.allow_request("anthropic")
        assert.is_true(ok)
    end)

    it("opens on transport errors", function()
        for i = 1, cb._FAILURE_THRESHOLD do
            cb.record("anthropic", nil, "connection refused")
        end
        local ok = cb.allow_request("anthropic")
        assert.is_false(ok)
    end)

    it("resets failures on success", function()
        for i = 1, cb._FAILURE_THRESHOLD - 1 do
            cb.record("anthropic", 500, nil)
        end
        cb.record("anthropic", 200, nil)
        cb.record("anthropic", 500, nil)  -- only 1 failure after success
        local ok = cb.allow_request("anthropic")
        assert.is_true(ok)
    end)

    it("transitions to half_open after cooldown", function()
        for i = 1, cb._FAILURE_THRESHOLD do
            cb.record("anthropic", 500, nil)
        end
        -- Still open before cooldown
        local ok1 = cb.allow_request("anthropic")
        assert.is_false(ok1)
        -- Advance time past cooldown
        _now = _now + cb._COOLDOWN_SECONDS + 1
        local ok2 = cb.allow_request("anthropic")
        assert.is_true(ok2)  -- probe allowed
        -- Second call in half_open should be blocked (probing)
        local ok3, reason = cb.allow_request("anthropic")
        assert.is_false(ok3)
        assert.equals("circuit_probing", reason)
    end)

    it("closes on successful probe", function()
        for i = 1, cb._FAILURE_THRESHOLD do
            cb.record("anthropic", 500, nil)
        end
        _now = _now + cb._COOLDOWN_SECONDS + 1
        cb.allow_request("anthropic")  -- enters half_open
        cb.record("anthropic", 200, nil)  -- probe succeeds
        local ok = cb.allow_request("anthropic")
        assert.is_true(ok)
    end)

    it("reopens on failed probe", function()
        for i = 1, cb._FAILURE_THRESHOLD do
            cb.record("anthropic", 500, nil)
        end
        _now = _now + cb._COOLDOWN_SECONDS + 1
        cb.allow_request("anthropic")  -- enters half_open
        cb.record("anthropic", 500, nil)  -- probe fails
        local ok, reason = cb.allow_request("anthropic")
        assert.is_false(ok)
        assert.equals("circuit_open", reason)
    end)

    it("isolates state per provider", function()
        for i = 1, cb._FAILURE_THRESHOLD do
            cb.record("anthropic", 500, nil)
        end
        local ok = cb.allow_request("openai")
        assert.is_true(ok)  -- anthropic is open, openai is not
    end)
end)
