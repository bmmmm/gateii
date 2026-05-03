-- rl_persist.lua: persist rate-limit gauges to disk so they survive container
-- restarts. Without this, every `docker compose up --force-recreate` zeroes
-- the shared dict and the dashboard shows "No data" until a real request
-- comes in to refresh it.
--
-- State is read on worker-0 startup and rewritten every PERSIST_INTERVAL
-- seconds. Stale values (reset timestamps in the past) are still loaded —
-- metrics.lua already emits 0 for expired windows, so the defensive layer
-- there hides any staleness from the dashboard.

local _M = {}
local cjson = require "cjson.safe"
local util = require "util"

local STATE_PATH = "/etc/nginx/data/ratelimit_state.json"
local PERSIST_INTERVAL_SECONDS = 30

-- Keys mirrored between shared dict and the on-disk JSON. Order doesn't matter
-- but keep the list in one place so save/load can't drift.
local KEYS = {
    "ratelimit_5h_utilization",
    "ratelimit_7d_utilization",
    "ratelimit_remaining",
    "ratelimit_reset_ts",
    "ratelimit_7d_reset_ts",
    "ratelimit_fallback_pct",
    "ratelimit_tokens_expired",
}

local function save_state()
    local cd = ngx.shared.counters
    local snapshot = {}
    local non_empty = false
    for _, k in ipairs(KEYS) do
        local v = cd:get(k)
        if v ~= nil then
            snapshot[k] = v
            non_empty = true
        end
    end
    if not non_empty then return end  -- nothing to save yet

    local payload = cjson.encode(snapshot)
    if not payload then return end
    local ok, err = util.atomic_write(STATE_PATH, payload)
    if not ok then ngx.log(ngx.WARN, "rl_persist: ", err) end
end

function _M.load_state()
    local f = io.open(STATE_PATH, "r")
    if not f then return end  -- first run, nothing to load
    local data = f:read("*a")
    f:close()
    local snapshot = cjson.decode(data)
    if type(snapshot) ~= "table" then
        ngx.log(ngx.WARN, "rl_persist: state file unparseable, ignoring")
        return
    end
    local cd = ngx.shared.counters
    local restored = 0
    for _, k in ipairs(KEYS) do
        local v = snapshot[k]
        if v ~= nil then
            cd:set(k, v)
            restored = restored + 1
        end
    end
    ngx.log(ngx.NOTICE, "rl_persist: restored ", restored, " keys from ", STATE_PATH)
end

function _M.start_persist_timer()
    local ok, err = ngx.timer.every(PERSIST_INTERVAL_SECONDS, function(premature)
        if premature then return end
        save_state()
    end)
    if not ok then
        ngx.log(ngx.ERR, "rl_persist: timer init failed — ", err)
    else
        ngx.log(ngx.NOTICE, "rl_persist: persist timer started, interval=",
            PERSIST_INTERVAL_SECONDS, "s")
    end
end

-- Exposed for testing / explicit flush.
_M.save_state = save_state

return _M
