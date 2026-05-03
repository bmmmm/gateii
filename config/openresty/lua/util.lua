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
    f:write(content)
    f:close()
    local ok, rename_err = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return nil, "rename " .. tmp .. " → " .. path .. " failed: " .. tostring(rename_err)
    end
    return true, nil
end

return _M
