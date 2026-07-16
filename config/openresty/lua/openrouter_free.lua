-- openrouter_free.lua: cached loader for data/openrouter-free.json — the
-- admin-managed OpenRouter free-tier config { pool, default }.
--   pool    = ordered :free model ids injected as the OpenRouter `models`
--             fallback array (empty → handler falls back to the provider's
--             hardcoded free_fallback_pool).
--   default = a :free model id that a model-less / non-:free request to a
--             free-only provider is rewritten to (empty → reject with 400).
-- handler.lua calls load() on every :free request, so the decode is cached with
-- a short TTL (this config changes rarely; a few seconds of post-save staleness
-- is fine and avoids a per-request file read+decode).
local cjson = require "cjson.safe"

local _M = {}
local CONFIG_PATH = "/etc/nginx/data/openrouter-free.json"
local TTL = 10
local _cache, _cache_ts = nil, -1

function _M.load()
    local now = ngx.time()
    if _cache ~= nil and (now - _cache_ts) < TTL then
        return _cache
    end
    local cfg = {}
    local f = io.open(CONFIG_PATH, "r")
    if f then
        local raw = f:read("*a"); f:close()
        local decoded = raw and cjson.decode(raw)
        if type(decoded) == "table" then cfg = decoded end
    end
    _cache = cfg
    _cache_ts = now
    return cfg
end

return _M
