-- Tests for circuit breaker state machine.
-- Run with: busted spec/circuit_breaker_spec.lua
--
-- Uses a FAITHFUL ngx.shared mock: get/set/add/incr/delete with TTL semantics
-- bound to a mockable clock. The breaker relies on add() as an atomic
-- cross-worker probe-claim and incr() for the failure counter, so a get/set-only
-- stub silently fails to exercise the half_open path (and errors on nil methods).

-- ---- faithful ngx.shared mock --------------------------------------------
local clock = { now = 1700000000 }
local store = {}            -- k -> {value=, exp=}  (exp = absolute expiry or nil)

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
function counters:add(k, v, ttl)
    if live(store[k]) then return false, "exists" end
    store[k] = { value = v, exp = (ttl and ttl > 0) and (clock.now + ttl) or nil }
    return true
end
function counters:incr(k, n, init, init_ttl)
    local e = store[k]
    if live(e) then
        e.value = e.value + n               -- keep existing expiry (OpenResty semantics)
        return e.value
    end
    if init == nil then return nil, "not found" end
    store[k] = { value = init + n,
                 exp = (init_ttl and init_ttl > 0) and (clock.now + init_ttl) or nil }
    return store[k].value
end
function counters:delete(k) store[k] = nil end

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
    package.loaded.circuit_breaker = nil
end

describe("circuit_breaker", function()
    local cb
    before_each(function()
        reset_state()
        cb = require "circuit_breaker"
    end)

    local function open_breaker()
        for _ = 1, cb._FAILURE_THRESHOLD do cb.record("anthropic", 500, nil) end
    end

    it("allows requests when closed", function()
        local ok, _ = cb.allow_request("anthropic")
        assert.is_true(ok)
    end)

    it("opens after threshold consecutive failures", function()
        open_breaker()
        local ok, reason = cb.allow_request("anthropic")
        assert.is_false(ok)
        assert.equals("circuit_open", reason)
    end)

    it("does not open on 4xx failures", function()
        for _ = 1, cb._FAILURE_THRESHOLD + 2 do cb.record("anthropic", 429, nil) end
        local ok = cb.allow_request("anthropic")
        assert.is_true(ok)
    end)

    it("opens on transport errors", function()
        for _ = 1, cb._FAILURE_THRESHOLD do cb.record("anthropic", nil, "connection refused") end
        local ok = cb.allow_request("anthropic")
        assert.is_false(ok)
    end)

    it("resets failures on success", function()
        for _ = 1, cb._FAILURE_THRESHOLD - 1 do cb.record("anthropic", 500, nil) end
        cb.record("anthropic", 200, nil)
        cb.record("anthropic", 500, nil)  -- only 1 failure after success
        local ok = cb.allow_request("anthropic")
        assert.is_true(ok)
    end)

    it("transitions to half_open after cooldown", function()
        open_breaker()
        assert.is_false((cb.allow_request("anthropic")))      -- open before cooldown
        clock.now = clock.now + cb._COOLDOWN_SECONDS + 1
        assert.is_true((cb.allow_request("anthropic")))       -- probe allowed
        local ok3, reason = cb.allow_request("anthropic")     -- 2nd caller blocked
        assert.is_false(ok3)
        assert.equals("circuit_probing", reason)
    end)

    it("closes on successful probe", function()
        open_breaker()
        clock.now = clock.now + cb._COOLDOWN_SECONDS + 1
        cb.allow_request("anthropic")     -- enters half_open
        cb.record("anthropic", 200, nil)  -- probe succeeds
        assert.is_true((cb.allow_request("anthropic")))
    end)

    it("reopens on failed probe", function()
        open_breaker()
        clock.now = clock.now + cb._COOLDOWN_SECONDS + 1
        cb.allow_request("anthropic")     -- enters half_open
        cb.record("anthropic", 500, nil)  -- probe fails
        local ok, reason = cb.allow_request("anthropic")
        assert.is_false(ok)
        assert.equals("circuit_open", reason)
    end)

    it("isolates state per provider", function()
        open_breaker()
        local ok = cb.allow_request("openai")
        assert.is_true(ok)  -- anthropic is open, openai is not
    end)

    -- ---- atomic-claim / probe-lifetime invariants ------------------------
    -- A slow-but-healthy probe must NOT let the breaker fail open. Streaming
    -- reads can take up to 120s/chunk, so the half_open state must survive far
    -- longer than the cooldown — otherwise the state key expires to the
    -- "closed" default mid-probe and every worker stampedes the upstream.
    it("does not fail open while a slow probe is still running", function()
        open_breaker()
        clock.now = clock.now + cb._COOLDOWN_SECONDS + 1
        assert.is_true((cb.allow_request("anthropic")))   -- probe taken
        clock.now = clock.now + 90                         -- probe still running
        local ok, reason = cb.allow_request("anthropic")
        assert.is_false(ok)
        assert.equals("circuit_probing", reason)
    end)

    -- A probe that dies without calling record() (worker crash) leaves an
    -- orphaned half_open. Once the claim TTL elapses, exactly ONE worker must
    -- be allowed to re-probe — not block forever, not stampede.
    it("re-probes once when the probe claim has expired", function()
        open_breaker()
        clock.now = clock.now + cb._COOLDOWN_SECONDS + 1
        cb.allow_request("anthropic")     -- half_open, claim taken
        clock.now = clock.now + 200       -- > probe-claim TTL, claim gone, state persists
        local ok1 = cb.allow_request("anthropic")
        local ok2, reason = cb.allow_request("anthropic")
        assert.is_true(ok1)               -- one worker re-probes
        assert.is_false(ok2)              -- the next is blocked again
        assert.equals("circuit_probing", reason)
    end)

    -- opened_at can be LRU-evicted while state=open survives. A 0 default would
    -- make "now - 0 >= cooldown" trivially true and probe immediately; instead
    -- re-arm the cooldown and stay open.
    it("fails safe when opened_at is evicted but state survives", function()
        counters:set("cb|anthropic|state", "open", 3600)   -- state present, no opened_at
        local ok, reason = cb.allow_request("anthropic")
        assert.is_false(ok)
        assert.equals("circuit_open", reason)
        assert.is_not_nil(counters:get("cb|anthropic|opened_at"))  -- re-armed
    end)
end)
