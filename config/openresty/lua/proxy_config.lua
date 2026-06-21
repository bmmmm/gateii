-- proxy_config.lua: worker-level config cache (loaded once per worker via require)
-- Shared across all requests in the same worker; avoids repeated C calls for
-- os.getenv() lookups and keys.json disk reads.
local cjson = require "cjson.safe"
local util  = require "util"

local _M = {}

local KEYS_PATH = "/etc/nginx/data/keys.json"
-- Cross-worker keys.json write lock + generation counter, in the quiet
-- `blocking` dict (process-wide, far less contended than `counters`, always
-- present). keys_gen is bumped after every successful write so every worker's
-- load_keys() reloads on its next request.
local LOCK_KEY = "keys_write_lock"
local GEN_KEY  = "keys_gen"

-- Environment variables — read once at module load time (never change during worker lifetime)
_M.PROXY_MODE       = os.getenv("PROXY_MODE") or "apikey"
_M.PASSTHROUGH_USER = os.getenv("PASSTHROUGH_USER") or "passthrough"

-- keys.json cache — at most one disk read per 10s per worker
local _keys     = {}
local _keys_ts  = 0
local _keys_gen = -1   -- last-seen generation; -1 forces the first load

function _M.load_keys()
    local now = ngx.now()
    local gen = ngx.shared.blocking:get(GEN_KEY) or 0
    -- Serve the cached snapshot only if it's fresh AND no writer bumped the
    -- generation since we loaded it. The gen check gives immediate cross-worker
    -- invalidation on add/revoke; the 10s window is just the no-change throttle.
    if _keys_ts > 0 and (now - _keys_ts) < 10 and gen == _keys_gen then
        return _keys
    end
    local f = io.open(KEYS_PATH, "r")
    if not f then
        _keys     = {}
        _keys_ts  = now
        _keys_gen = gen
        return _keys
    end
    local raw = f:read("*a")
    f:close()
    local parsed, derr = cjson.decode(raw)
    if parsed == nil then
        -- Corrupt JSON (e.g. operator hand-edit mid-flight): keep the previous
        -- good cache and retry next cycle. Caching {} here would make auth.lua
        -- negative-cache valid keys for AUTH_CACHE_NEG_TTL → 401 storm. Mirrors
        -- the bootstrap keys reader. The missing-file branch above keeps {}
        -- because an absent keys.json legitimately means "no keys".
        ngx.log(ngx.ERR, "proxy_config: keys.json decode failed, keeping previous cache: ", tostring(derr))
        return _keys
    end
    _keys     = parsed
    _keys_ts  = now
    _keys_gen = gen
    return _keys
end

-- Serialize the whole read-modify-write of keys.json across nginx workers, then
-- bump the generation counter so every worker's load_keys() reloads on its next
-- request. mutate_fn(tbl) edits the decoded table in place; return false to abort
-- without writing. Returns (true, nil) or (nil, err). Callers run in
-- content_by_lua / timer phases, where ngx.sleep (yield) is permitted.
function _M.update_keys(mutate_fn)
    local bd = ngx.shared.blocking
    local deadline = ngx.now() + 2
    while not bd:add(LOCK_KEY, 1, 5) do   -- 5s TTL = crash backstop for the lock
        if ngx.now() > deadline then return nil, "keys.json write lock timeout" end
        ngx.sleep(0.01)
    end

    local ok, err = pcall(function()
        -- Fresh read INSIDE the lock — never reuse a pre-lock snapshot.
        local tbl = {}
        local f = io.open(KEYS_PATH, "r")
        if f then
            local raw = f:read("*a"); f:close()
            local parsed = cjson.decode(raw)
            -- Corrupt file: abort rather than overwriting it with {} (which would
            -- wipe every key). The caller surfaces the error.
            if parsed == nil then error("keys.json decode failed; refusing to overwrite") end
            tbl = parsed
        end
        if mutate_fn(tbl) == false then return end   -- aborted: no write, no bump
        local encoded = cjson.encode(tbl)
        if not encoded then error("keys.json encode failed") end
        local wok, werr = util.atomic_write(KEYS_PATH, encoded)
        if not wok then error(tostring(werr)) end
        bd:incr(GEN_KEY, 1, 0)   -- signal all workers to reload
    end)

    bd:delete(LOCK_KEY)
    if not ok then return nil, tostring(err) end
    return true
end

-- Today's UTC date string (YYYY-MM-DD) — refreshed at most once per 60s
local _today    = ""
local _today_ts = 0

function _M.get_today()
    local now = ngx.time()
    if now - _today_ts >= 60 then
        _today    = os.date("!%Y-%m-%d", now)
        _today_ts = now
    end
    return _today
end

return _M
