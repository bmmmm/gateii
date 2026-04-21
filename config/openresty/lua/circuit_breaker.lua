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

local FAILURE_THRESHOLD = 5       -- open after 5 consecutive failures
local COOLDOWN_SECONDS  = 30      -- 30s before allowing probe
local STATE_TTL         = 3600    -- 1h TTL on state keys (auto-cleanup)

local function key(provider, field)
    return "cb|" .. provider .. "|" .. field
end

-- Check if a request is allowed. Returns (allowed: bool, reason: string?).
-- When in open state AND cooldown elapsed, transitions to half_open and allows ONE probe.
function _M.allow_request(provider)
    local cd = ngx.shared.counters
    local state = cd:get(key(provider, "state")) or "closed"

    if state == "closed" then
        return true, nil
    end

    if state == "open" then
        local opened_at = cd:get(key(provider, "opened_at")) or 0
        if ngx.time() - opened_at >= COOLDOWN_SECONDS then
            -- Transition to half_open — allow one probe
            cd:set(key(provider, "state"), "half_open", STATE_TTL)
            ngx.log(ngx.NOTICE, "circuit_breaker: ", provider, " transitioning to half_open")
            return true, nil
        end
        return false, "circuit_open"
    end

    if state == "half_open" then
        -- Already probing — deny further requests until probe completes
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
        local failures = (cd:get(key(provider, "failures")) or 0) + 1
        cd:set(key(provider, "failures"), failures, STATE_TTL)

        if state == "half_open" then
            -- Probe failed — back to open, reset cooldown timer
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
        -- Success — reset
        if state == "half_open" then
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
