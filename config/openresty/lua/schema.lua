-- schema.lua: hand-written config validators.
-- Each validator returns (ok: bool, err: string?). err is a human-readable
-- message with a path like "providers[0].pricing.input_per_mtok".
local cjson = require "cjson.safe"

local _M = {}

local function is_table(v) return type(v) == "table" end
local function is_string(v) return type(v) == "string" and v ~= "" end
local function is_number(v) return type(v) == "number" end
local function is_pos_int(v) return is_number(v) and v > 0 and math.floor(v) == v end
local function is_nonneg_number(v) return is_number(v) and v >= 0 end

-- Validate providers.json structure
function _M.validate_providers(data)
    if not is_table(data) then
        return false, "providers.json: root must be an object"
    end
    if not is_string(data.active_provider) then
        return false, "providers.json: active_provider must be a non-empty string"
    end
    if not is_table(data.providers) or #data.providers == 0 then
        return false, "providers.json: providers must be a non-empty array"
    end

    local ids = {}
    for i, p in ipairs(data.providers) do
        local path = "providers[" .. (i - 1) .. "]"
        if not is_table(p) then
            return false, path .. ": must be an object"
        end
        if not is_string(p.id) then
            return false, path .. ".id: must be a non-empty string"
        end
        if ids[p.id] then
            return false, path .. ".id: duplicate id '" .. p.id .. "'"
        end
        ids[p.id] = true
        if p.tokens_window_limit ~= nil and not is_pos_int(p.tokens_window_limit) then
            return false, path .. ".tokens_window_limit: must be a positive integer"
        end
        if p.window_seconds ~= nil and not is_pos_int(p.window_seconds) then
            return false, path .. ".window_seconds: must be a positive integer"
        end
        -- Pricing is optional but if present must be well-formed
        if p.pricing ~= nil then
            if not is_table(p.pricing) then
                return false, path .. ".pricing: must be an object"
            end
            for model, prices in pairs(p.pricing) do
                local mpath = path .. ".pricing." .. model
                if not is_table(prices) then
                    return false, mpath .. ": must be an object with input/output prices"
                end
                -- Allow either flat {input,output} or pattern-matched structure; just check types
                for k, v in pairs(prices) do
                    if type(v) == "number" and v < 0 then
                        return false, mpath .. "." .. k .. ": prices must be non-negative"
                    end
                end
            end
        end
    end

    -- active_provider must reference an existing id
    if not ids[data.active_provider] then
        return false, "providers.json: active_provider '" .. data.active_provider
            .. "' does not match any provider id"
    end

    return true, nil
end

-- Validate limits.json structure (map of user -> {tokens_per_day, requests_per_day})
function _M.validate_limits(data)
    if not is_table(data) then
        return false, "limits.json: root must be an object (map user -> limits)"
    end
    for user, limits in pairs(data) do
        if not is_string(user) then
            return false, "limits.json: user keys must be strings"
        end
        if not is_table(limits) then
            return false, "limits.json['" .. user .. "']: must be an object"
        end
        if limits.tokens_per_day ~= nil and not is_pos_int(limits.tokens_per_day) then
            return false, "limits.json['" .. user .. "'].tokens_per_day: must be a positive integer"
        end
        if limits.requests_per_day ~= nil and not is_pos_int(limits.requests_per_day) then
            return false, "limits.json['" .. user .. "'].requests_per_day: must be a positive integer"
        end
    end
    return true, nil
end

-- Validate keys.json — structured format:
--   { "<api_key>": { "user":"...", "provider":"...", "upstream_key":"...",
--                    "created_at":"?", "bootstrap_code":"?" } }
-- Flat {key: user-string} format is rejected (abolished).
function _M.validate_keys(data)
    if not is_table(data) then
        return false, "keys.json: root must be an object (map key -> {user, provider, upstream_key})"
    end
    for key, entry in pairs(data) do
        if not is_string(key) then
            return false, "keys.json: key must be a non-empty string"
        end
        if #key < 8 then
            return false, "keys.json: key '" .. key:sub(1, 8) .. "...' too short (min 8 chars)"
        end
        local short = key:sub(1, 12) .. "..."
        if type(entry) ~= "table" then
            return false, "keys.json[" .. short .. "]: value must be an object with user/provider/upstream_key"
                .. " (flat {key:user} format is no longer supported — run admin.sh migrate)"
        end
        if not is_string(entry.user) then
            return false, "keys.json[" .. short .. "].user: must be a non-empty string"
        end
        if not is_string(entry.provider) then
            return false, "keys.json[" .. short .. "].provider: must be a non-empty string"
        end
        if not is_string(entry.upstream_key) then
            return false, "keys.json[" .. short .. "].upstream_key: must be a non-empty string"
        end
    end
    return true, nil
end

-- git-tracking.json: { "default_author": "bma", "interval": 300, "repos": [
--   { "path": "/repos/gateii", "author": "bma", "platform": "forgejo", "alias": "gateii" }, … ]
-- }
-- All fields except path are optional. Platform is free-text but the UI offers
-- a known set (github / gitlab / forgejo / gitea / codeberg / bitbucket / local).
local PLATFORM_PATTERN = "^[a-z0-9_-]+$"

function _M.validate_git_tracking(data)
    if not is_table(data) then
        return false, "git-tracking.json: root must be an object"
    end
    -- Optional fields: empty string is valid (means "not set"), but if non-empty
    -- it must be a real string. The local is_string helper rejects empty strings,
    -- which would break the UI's default-state PUT (all fields empty until typed).
    if data.default_author ~= nil and type(data.default_author) ~= "string" then
        return false, "git-tracking.json: default_author must be a string"
    end
    if data.interval ~= nil and (type(data.interval) ~= "number" or data.interval < 30) then
        return false, "git-tracking.json: interval must be a number ≥ 30 (seconds)"
    end
    if data.repos == nil then return true, nil end  -- empty config valid
    if type(data.repos) ~= "table" then
        return false, "git-tracking.json: repos must be an array"
    end
    for i, r in ipairs(data.repos) do
        if type(r) ~= "table" then
            return false, "git-tracking.json: repos[" .. i .. "] must be an object"
        end
        if not is_string(r.path) then
            return false, "git-tracking.json: repos[" .. i .. "].path required (non-empty string)"
        end
        if r.author ~= nil and type(r.author) ~= "string" then
            return false, "git-tracking.json: repos[" .. i .. "].author must be a string"
        end
        if r.platform ~= nil and r.platform ~= "" then
            if type(r.platform) ~= "string" or not r.platform:match(PLATFORM_PATTERN) then
                return false, "git-tracking.json: repos[" .. i ..
                    "].platform must match [a-z0-9_-]+ (e.g. forgejo, github, gitlab)"
            end
        end
        if r.alias ~= nil and type(r.alias) ~= "string" then
            return false, "git-tracking.json: repos[" .. i .. "].alias must be a string"
        end
    end
    return true, nil
end

-- Load + parse + validate a JSON file.
-- Returns (data, err). On validation failure, err contains the reason.
-- Missing file is NOT an error -- returns (nil, nil).
function _M.load_validated(path, validator)
    local f = io.open(path, "r")
    if not f then return nil, nil end
    local raw = f:read("*a"); f:close()
    if not raw or raw == "" then return nil, nil end

    local data, decode_err = cjson.decode(raw)
    if not data then
        return nil, path .. ": JSON parse error: " .. tostring(decode_err)
    end

    local ok, err = validator(data)
    if not ok then
        return nil, err
    end
    return data, nil
end

return _M
