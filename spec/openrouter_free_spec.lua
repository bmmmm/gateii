-- Tests for openrouter_free budget bookkeeping: X-RateLimit-Reset parsing,
-- window counting, exhaustion arming. Run with: busted spec/openrouter_free_spec.lua
--
-- Uses the same faithful ngx.shared mock as circuit_breaker_spec (get/set/incr
-- with TTL semantics bound to a mockable clock). The TTL fidelity matters for
-- arm_exhaustion (its expiry IS the un-arm mechanism); the budget windows roll
-- over by KEY change (minute/day in the key), their TTLs are only dict cleanup
-- and are not asserted here.

-- ---- faithful ngx.shared mock --------------------------------------------
local clock = { now = 1700000000 }
local store = {}

local function live(e)
    return e ~= nil and (e.exp == nil or clock.now < e.exp)
end

local counters = {}
function counters:get(k)
    local e = store[k]
    if live(e) then return e.value end
    store[k] = nil
    return nil
end
function counters:set(k, v, ttl)
    store[k] = { value = v, exp = (ttl and ttl > 0) and (clock.now + ttl) or nil }
    return true
end
function counters:incr(k, n, init, init_ttl)
    local e = store[k]
    if live(e) then
        e.value = e.value + n
        return e.value
    end
    if init == nil then return nil, "not found" end
    store[k] = { value = init + n,
                 exp = (init_ttl and init_ttl > 0) and (clock.now + init_ttl) or nil }
    return store[k].value
end

_G.ngx = {
    shared = { counters = counters },
    time   = function() return clock.now end,
    log    = function() end,
    ERR  = 1, WARN = 2, NOTICE = 3, INFO = 4,
}

package.path = package.path .. ";config/openresty/lua/?.lua"

local function reset_state()
    for k in pairs(store) do store[k] = nil end
    clock.now = 1700000000
    -- util caches today's date until the next UTC midnight — must reload when
    -- the clock rewinds between tests.
    package.loaded.openrouter_free = nil
    package.loaded.util = nil
end

describe("openrouter_free.parse_reset", function()
    local orf
    before_each(function()
        reset_state()
        orf = require "openrouter_free"
    end)

    it("parses unix seconds in the future", function()
        assert.equals(clock.now + 300, orf.parse_reset(tostring(clock.now + 300), clock.now))
    end)

    it("parses unix milliseconds", function()
        local reset_s = clock.now + 300
        assert.equals(reset_s, orf.parse_reset(tostring(reset_s * 1000), clock.now))
    end)

    it("parses delta seconds", function()
        assert.equals(clock.now + 45, orf.parse_reset("45", clock.now))
    end)

    it("rejects nil, garbage, zero and negatives", function()
        assert.is_nil(orf.parse_reset(nil, clock.now))
        assert.is_nil(orf.parse_reset("soon", clock.now))
        assert.is_nil(orf.parse_reset("0", clock.now))
        assert.is_nil(orf.parse_reset("-30", clock.now))
    end)

    it("rejects a reset in the past", function()
        assert.is_nil(orf.parse_reset(tostring(clock.now - 10), clock.now))
    end)

    it("caps a bogus far-future reset at ~26h", function()
        local week_away = clock.now + 7 * 86400
        assert.equals(clock.now + 26 * 3600, orf.parse_reset(tostring(week_away), clock.now))
    end)
end)

describe("openrouter_free budget windows", function()
    local orf
    before_each(function()
        reset_state()
        orf = require "openrouter_free"
    end)

    it("counts bumps into the current minute and day windows", function()
        orf.bump_budget()
        orf.bump_budget()
        local b = orf.budget_snapshot({})
        assert.equals(2, b.minute.used)
        assert.equals(2, b.day.used)
    end)

    it("minute window rolls over, day window persists", function()
        orf.bump_budget()
        clock.now = clock.now + 61
        orf.bump_budget()
        local b = orf.budget_snapshot({})
        assert.equals(1, b.minute.used)
        assert.equals(2, b.day.used)
    end)

    it("day window resets at UTC midnight", function()
        orf.bump_budget()
        -- jump past the next UTC midnight
        clock.now = (math.floor(clock.now / 86400) + 1) * 86400 + 5
        local b = orf.budget_snapshot({})
        assert.equals(0, b.day.used)
    end)

    it("uses default limits 20/min and 50/day, remaining clamped at 0", function()
        local b = orf.budget_snapshot({})
        assert.equals(20, b.minute.limit)
        assert.equals(50, b.day.limit)
        for _ = 1, 55 do orf.bump_budget() end
        b = orf.budget_snapshot({})
        assert.equals(0, b.day.remaining)
    end)

    it("respects configured limits", function()
        local b = orf.budget_snapshot({ minute_limit = 20, daily_limit = 1000 })
        assert.equals(1000, b.day.limit)
        assert.equals(1000, b.day.remaining)
    end)

    it("limits() falls back to 20/50 and reads configured overrides", function()
        local m, d = orf.limits(nil)
        assert.equals(20, m); assert.equals(50, d)
        m, d = orf.limits({ minute_limit = 30, daily_limit = 1000 })
        assert.equals(30, m); assert.equals(1000, d)
    end)
end)

describe("openrouter_free exhaustion signal", function()
    local orf
    before_each(function()
        reset_state()
        orf = require "openrouter_free"
    end)

    it("is nil when never armed", function()
        assert.is_nil(orf.get_exhausted_until())
        assert.is_nil(orf.budget_snapshot({}).exhausted_until)
    end)

    it("arms until the reset and reports the hit limit", function()
        orf.arm_exhaustion(clock.now + 120, 50)
        assert.equals(clock.now + 120, orf.get_exhausted_until())
        local b = orf.budget_snapshot({})
        assert.equals(clock.now + 120, b.exhausted_until)
        assert.equals(50, b.exhausted_limit)
    end)

    it("expires with the reset time", function()
        orf.arm_exhaustion(clock.now + 60, 20)
        clock.now = clock.now + 61
        assert.is_nil(orf.get_exhausted_until())
    end)

    it("ignores a reset that is not in the future", function()
        orf.arm_exhaustion(clock.now, 50)
        assert.is_nil(orf.get_exhausted_until())
    end)
end)
