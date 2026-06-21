-- proxy_config.lua: worker-level config cache (loaded once per worker via require)
-- Shared across all requests in the same worker; avoids repeated C calls for
-- os.getenv() lookups and keys.json disk reads.
local cjson = require "cjson.safe"

local _M = {}

-- Environment variables — read once at module load time (never change during worker lifetime)
_M.PROXY_MODE       = os.getenv("PROXY_MODE") or "apikey"
_M.PASSTHROUGH_USER = os.getenv("PASSTHROUGH_USER") or "passthrough"

-- keys.json cache — at most one disk read per 10s per worker
local _keys    = {}
local _keys_ts = 0

function _M.load_keys()
    local now = ngx.now()
    if _keys_ts > 0 and (now - _keys_ts) < 10 then
        return _keys
    end
    local f = io.open("/etc/nginx/data/keys.json", "r")
    if not f then
        _keys    = {}
        _keys_ts = now
        return _keys
    end
    local raw = f:read("*a")
    f:close()
    local parsed, derr = cjson.decode(raw)
    if parsed == nil then
        -- Corrupt JSON (e.g. operator hand-edit mid-flight): keep the previous
        -- good cache and retry next cycle. Caching {} here would make auth.lua
        -- negative-cache valid keys for AUTH_CACHE_NEG_TTL → 401 storm. Mirrors
        -- bootstrap.lua keys_read(). The missing-file branch above keeps {}
        -- because an absent keys.json legitimately means "no keys".
        ngx.log(ngx.ERR, "proxy_config: keys.json decode failed, keeping previous cache: ", tostring(derr))
        return _keys
    end
    _keys    = parsed
    _keys_ts = now
    return _keys
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
