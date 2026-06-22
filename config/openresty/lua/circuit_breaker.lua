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

-- PROBE_CLAIM_TTL bounds a single in-flight probe: it auto-clears the claim if
-- the probe dies without calling record() (deadlock prevention) so re-probing can
-- resume. It MUST exceed the worst-case probe duration — the streaming read
-- timeout is 120s per chunk (handler.lua set_timeouts) — otherwise a slow but
-- healthy probe's claim expires and a second worker stampedes the upstream.
-- 180s = 120s + slack. The state key uses STATE_TTL so it never expires mid-probe.
local PROBE_CLAIM_TTL = 180

-- Check if a request is allowed. Returns (allowed: bool, reason: string?).
-- When in open state AND cooldown elapsed, exactly ONE worker transitions to half_open
-- and sends the probe; all others are blocked until the probe completes or times out.
function _M.allow_request(provider)
    local cd = ngx.shared.counters
    local state = cd:get(key(provider, "state")) or "closed"
    local claim_key = key(provider, "probe_claim")

    if state == "closed" then
        return true, nil
    end

    if state == "open" then
        local opened_at = cd:get(key(provider, "opened_at"))
        if not opened_at then
            -- opened_at was LRU-evicted but state survived: fail safe — restart
            -- the cooldown instead of probing immediately (a 0 default makes
            -- "now - 0 >= COOLDOWN" trivially true). Re-persist, stay open.
            cd:set(key(provider, "opened_at"), ngx.time(), STATE_TTL)
            return false, "circuit_open"
        end
        if ngx.time() - opened_at >= COOLDOWN_SECONDS then
            -- Atomic claim: cd:add only succeeds for the FIRST caller (key must
            -- not exist). The winner transitions to half_open and sends the
            -- single probe; the claim's bounded TTL auto-clears a dead probe.
            -- state uses STATE_TTL so it cannot expire to the "closed" default
            -- while a slow probe is still in flight (which would let everyone in).
            if cd:add(claim_key, 1, PROBE_CLAIM_TTL) then
                cd:set(key(provider, "state"), "half_open", STATE_TTL)
                ngx.log(ngx.NOTICE, "circuit_breaker: ", provider, " transitioning to half_open")
                return true, nil
            end
            -- Another worker already claimed the probe — block until it completes
            return false, "circuit_probing"
        end
        return false, "circuit_open"
    end

    if state == "half_open" then
        -- A probe should be in flight. If its claim has expired (the probe died
        -- without calling record), let exactly one worker re-probe rather than
        -- blocking forever on an orphaned half_open state.
        if cd:get(claim_key) == nil and cd:add(claim_key, 1, PROBE_CLAIM_TTL) then
            ngx.log(ngx.NOTICE, "circuit_breaker: ", provider, " stale probe claim — re-probing")
            return true, nil
        end
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
        -- incr returns nil when the dict must allocate but is full; coerce to 0 so
        -- the `failures >= FAILURE_THRESHOLD` compare below never blows up on nil
        -- (no record() call site wraps this in pcall). A full-dict round just
        -- doesn't trip the breaker instead of crashing the request.
        local failures = cd:incr(key(provider, "failures"), 1, 0, STATE_TTL)
        if not failures then
            ngx.log(ngx.WARN, "circuit_breaker: ", provider,
                    " failures incr returned nil (counters dict full, free_space=",
                    cd:free_space(), ") — not tripping breaker this round")
            failures = 0
        end

        if state == "half_open" then
            -- Probe failed — release claim, reopen with a fresh cooldown timer.
            cd:delete(key(provider, "probe_claim"))
            cd:set(key(provider, "state"), "open", STATE_TTL)
            cd:set(key(provider, "opened_at"), ngx.time(), STATE_TTL)
            cd:set(key(provider, "failures"), 0, STATE_TTL)   -- reset count on open
            ngx.log(ngx.WARN, "circuit_breaker: ", provider, " probe failed, reopening")
        elseif state == "closed" and failures >= FAILURE_THRESHOLD then
            cd:set(key(provider, "state"), "open", STATE_TTL)
            cd:set(key(provider, "opened_at"), ngx.time(), STATE_TTL)
            cd:set(key(provider, "failures"), 0, STATE_TTL)   -- reset count on open
            ngx.log(ngx.WARN, "circuit_breaker: ", provider, " opened after ",
                    failures, " consecutive failures")
        end
    else
        -- Success.
        if state == "half_open" then
            -- Probe succeeded — release claim and close.
            cd:delete(key(provider, "probe_claim"))
            cd:set(key(provider, "state"), "closed", STATE_TTL)
            ngx.log(ngx.NOTICE, "circuit_breaker: ", provider, " probe succeeded, closing")
        end
        -- Steady-state healthy path: absence of keys already reads as closed/0 in
        -- both allow_request and here, so skip the two unconditional writes per
        -- request on the contended counters dict — only clear a non-zero count.
        if (cd:get(key(provider, "failures")) or 0) ~= 0 then
            cd:set(key(provider, "failures"), 0, STATE_TTL)
        end
    end
end

-- Expose tunables for tests
_M._FAILURE_THRESHOLD = FAILURE_THRESHOLD
_M._COOLDOWN_SECONDS  = COOLDOWN_SECONDS

return _M
