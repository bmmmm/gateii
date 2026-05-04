-- circuit_breaker.lua: per-provider consecutive-failure breaker.
-- State stored in shared dict `counters` with keys:
--   cb|<provider>|state       → "closed" | "open" | "half_open"
--   cb|<provider>|failures    → consecutive failure count
--   cb|<provider>|opened_at   → unix timestamp when circuit opened
--
-- State transitions:
--   closed → open:      after FAILURE_THRESHOLD consecutive 5xx/timeout
--   open → half_open:   after COOLDOWN_SECONDS elapsed
--   half_open → closed: on successful response
--   half_open → open:   on any failure during probe
local _M = {}

-- Tuning (override via env, see .env.example).
local FAILURE_THRESHOLD = tonumber(os.getenv("CB_FAILURE_THRESHOLD")) or 5
local COOLDOWN_SECONDS  = tonumber(os.getenv("CB_COOLDOWN_SECONDS")) or 30
local STATE_TTL         = 3600    -- 1h TTL on state keys (auto-cleanup, not tuning-worthy)

local function key(provider, field)
    return "cb|" .. provider .. "|" .. field
end

-- TTL for half_open: auto-expires if the probe never calls record() (deadlock prevention).
-- Two cooldown cycles is long enough for a slow response, short enough to unblock eventually.
local HALF_OPEN_TTL = COOLDOWN_SECONDS * 2

-- Check if a request is allowed. Returns (allowed: bool, reason: string?).
-- When in open state AND cooldown elapsed, exactly ONE worker transitions to half_open
-- and sends the probe; all others are blocked until the probe completes or times out.
function _M.allow_request(provider)
    local cd = ngx.shared.counters
    local state = cd:get(key(provider, "state")) or "closed"

    if state == "closed" then
        return true, nil
    end

    if state == "open" then
        local opened_at = cd:get(key(provider, "opened_at")) or 0
        if ngx.time() - opened_at >= COOLDOWN_SECONDS then
            -- Atomic claim: cd:add only succeeds for the FIRST caller (key must not exist).
            -- The winner transitions to half_open and sends the single probe.
            -- HALF_OPEN_TTL auto-clears the claim if the probe never returns (no deadlock).
            local claim_key = key(provider, "probe_claim")
            local claimed = cd:add(claim_key, 1, HALF_OPEN_TTL)
            if claimed then
                cd:set(key(provider, "state"), "half_open", HALF_OPEN_TTL)
                ngx.log(ngx.NOTICE, "circuit_breaker: ", provider, " transitioning to half_open")
                return true, nil
            end
            -- Another worker already claimed the probe — block until it completes
            return false, "circuit_probing"
        end
        return false, "circuit_open"
    end

    if state == "half_open" then
        -- Probe in progress — deny until record() resolves it
        return false, "circuit_probing"
    end

    -- Unknown state → fail safe, allow
    return true, nil
end

-- Record the outcome of a request: status code + optional transport error.
-- A "failure" for breaker purposes is status >= 500 or a transport error (status=nil).
-- 4xx (including 429) does NOT trip the breaker — client errors are not upstream health.
function _M.record(provider, status, transport_err)
    local cd = ngx.shared.counters
    local is_failure = (transport_err ~= nil) or (status and status >= 500)
    local state = cd:get(key(provider, "state")) or "closed"

    if is_failure then
        local failures = cd:incr(key(provider, "failures"), 1, 0, STATE_TTL)

        if state == "half_open" then
            -- Probe failed — release claim, reset to open with fresh cooldown timer
            cd:delete(key(provider, "probe_claim"))
            cd:set(key(provider, "state"), "open", STATE_TTL)
            cd:set(key(provider, "opened_at"), ngx.time(), STATE_TTL)
            ngx.log(ngx.WARN, "circuit_breaker: ", provider, " probe failed, reopening")
        elseif state == "closed" and failures >= FAILURE_THRESHOLD then
            cd:set(key(provider, "state"), "open", STATE_TTL)
            cd:set(key(provider, "opened_at"), ngx.time(), STATE_TTL)
            ngx.log(ngx.WARN, "circuit_breaker: ", provider, " opened after ",
                    failures, " consecutive failures")
        end
    else
        -- Success — release probe claim and close circuit
        if state == "half_open" then
            cd:delete(key(provider, "probe_claim"))
            ngx.log(ngx.NOTICE, "circuit_breaker: ", provider, " probe succeeded, closing")
        end
        cd:set(key(provider, "state"), "closed", STATE_TTL)
        cd:set(key(provider, "failures"), 0, STATE_TTL)
    end
end

-- Expose tunables for tests
_M._FAILURE_THRESHOLD = FAILURE_THRESHOLD
_M._COOLDOWN_SECONDS  = COOLDOWN_SECONDS

return _M
