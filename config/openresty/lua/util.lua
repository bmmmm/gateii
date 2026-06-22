-- util.lua: small shared primitives that don't fit elsewhere.

local _M = {}

-- Write `content` to `path` atomically (tmp + rename). Returns (true, nil) on
-- success or (nil, err) on failure. Removes the tmp file if rename fails so
-- broken half-writes don't accumulate. Caller decides how to surface the
-- error (log + 500, log + return, …).
function _M.atomic_write(path, content)
    local tmp = path .. ".tmp"
    local f, open_err = io.open(tmp, "w")
    if not f then
        return nil, "open " .. tmp .. " failed: " .. tostring(open_err)
    end
    local ok_w, write_err = f:write(content)
    -- Buffered stdio flushes at close, so a close-flush failure (ENOSPC/quota/IO)
    -- means the temp is truncated even though write() returned ok. Treat a close
    -- failure as a write failure so we never rename a half-written temp over the
    -- good original.
    local ok_c, close_err = f:close()
    if not ok_w or not ok_c then
        os.remove(tmp)
        return nil, "write " .. tmp .. " failed: " .. tostring(write_err or close_err)
    end
    local ok, rename_err = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return nil, "rename " .. tmp .. " → " .. path .. " failed: " .. tostring(rename_err)
    end
    return true, nil
end

-- Sanitize a string for use as a shared-dict key component.
-- Replaces chars that break key parsing (colon, pipe, whitespace) with "_".
-- fallback: returned when s is nil/empty (default "unknown").
function _M.sanitize(s, fallback)
    fallback = fallback or "unknown"
    local v = tostring(s or "")
    if v == "" then return fallback end
    return (v:gsub("[:|%s]", "_"):sub(1, 64))
end

-- Today's UTC date string (YYYY-MM-DD), cached until the next UTC midnight.
-- A fixed 60s window risked returning yesterday after midnight for up to 60s;
-- expiring at midnight guarantees the cache flips exactly at the day boundary.
local _today         = ""
local _today_expires = 0
function _M.get_today()
    local now = ngx.time()
    if now >= _today_expires then
        _today         = os.date("!%Y-%m-%d", now)
        -- Next UTC midnight = next multiple of 86400 seconds since epoch
        _today_expires = (math.floor(now / 86400) + 1) * 86400
    end
    return _today
end

return _M
