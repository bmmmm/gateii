-- schema.lua: hand-written config validators.
-- Each validator returns (ok: bool, err: string?). err is a human-readable
-- message with a path like "providers[0].pricing.input_per_mtok".
local cjson = require "cjson.safe"

local _M = {}

local function is_table(v) return type(v) == "table" end
local function is_string(v) return type(v) == "string" end
local function is_nonempty_string(v) return type(v) == "string" and v ~= "" end
local function is_number(v) return type(v) == "number" end
local function is_pos_int(v) return is_number(v) and v > 0 and math.floor(v) == v end
local function is_nonneg_int(v) return is_number(v) and v >= 0 and math.floor(v) == v end
local function is_nonneg_number(v) return is_number(v) and v >= 0 end

-- Validate providers.json structure
function _M.validate_providers(data)
    if not is_table(data) then
        return false, "providers.json: root must be an object"
    end
    if not is_nonempty_string(data.active_provider) then
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
        if not is_nonempty_string(p.id) then
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
        -- Pricing lives in p.models (pattern-matched array consumed by metrics.lua).
        -- Optional, but if present must be a non-empty array of well-formed entries —
        -- a missing pattern makes metrics.lua's m:find(nil) raise and 500s /metrics.
        if p.models ~= nil then
            if not is_table(p.models) or #p.models == 0 then
                return false, path .. ".models: must be a non-empty array"
            end
            for j, entry in ipairs(p.models) do
                local mpath = path .. ".models[" .. (j - 1) .. "]"
                if not is_table(entry) then
                    return false, mpath .. ": must be an object"
                end
                if not is_nonempty_string(entry.pattern) then
                    return false, mpath .. ".pattern: must be a non-empty string"
                end
                if not is_nonneg_number(entry.input) then
                    return false, mpath .. ".input: must be a non-negative number"
                end
                if not is_nonneg_number(entry.output) then
                    return false, mpath .. ".output: must be a non-negative number"
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

-- Validate limits.json structure (map of user -> {tokens_per_day, requests_per_day}).
-- Per-entry tolerant: a single malformed entry must NOT drop the whole file, or one
-- fat-fingered limit silently removes every user's daily cap (limits fail OPEN).
-- Invalid entries are collected, removed from `data` in place, and WARN-logged;
-- the surviving valid entries load normally. Only a non-object root is a hard error.
-- Cap values use is_nonneg_int so a deliberate 0 cap (hard-zero, block everything)
-- is accepted; keys.json validation stays strict (auth must fail closed).
function _M.validate_limits(data)
    if not is_table(data) then
        return false, "limits.json: root must be an object (map user -> limits)"
    end
    local drop = {}
    for user, limits in pairs(data) do
        local reason
        if not is_nonempty_string(user) then
            reason = "user key must be a non-empty string"
        elseif not is_table(limits) then
            reason = "value must be an object"
        elseif limits.tokens_per_day ~= nil and not is_nonneg_int(limits.tokens_per_day) then
            reason = "tokens_per_day must be a non-negative integer"
        elseif limits.requests_per_day ~= nil and not is_nonneg_int(limits.requests_per_day) then
            reason = "requests_per_day must be a non-negative integer"
        end
        if reason then
            drop[#drop + 1] = user
            -- ngx is available at startup (init_by_lua) but not in unit tests; guard it
            -- so this pure validator stays loadable without an ngx stub.
            if ngx and ngx.log then
                ngx.log(ngx.WARN, "limits.json: skipping invalid entry '", tostring(user), "': ", reason)
            end
        end
    end
    for _, user in ipairs(drop) do
        data[user] = nil
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
        if not is_nonempty_string(key) then
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
        if not is_nonempty_string(entry.user) then
            return false, "keys.json[" .. short .. "].user: must be a non-empty string"
        end
        if not is_nonempty_string(entry.provider) then
            return false, "keys.json[" .. short .. "].provider: must be a non-empty string"
        end
        if not is_nonempty_string(entry.upstream_key) then
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
    -- Optional string fields use is_string (any string incl. "" = "not set");
    -- only `path` is required and uses is_nonempty_string.
    if data.default_author ~= nil and not is_string(data.default_author) then
        return false, "git-tracking.json: default_author must be a string"
    end
    if data.interval ~= nil and (type(data.interval) ~= "number" or data.interval < 30) then
        return false, "git-tracking.json: interval must be a number ≥ 30 (seconds)"
    end
    -- platform_authors: { "forgejo": "bma", "github": "bmmmm", … }
    -- Maps platform tag → git-author string used as fallback when a repo
    -- doesn't pin its own author. Platform keys must match PLATFORM_PATTERN.
    if data.platform_authors ~= nil then
        if type(data.platform_authors) ~= "table" then
            return false, "git-tracking.json: platform_authors must be an object"
        end
        for plat, author in pairs(data.platform_authors) do
            if type(plat) ~= "string" or not plat:match(PLATFORM_PATTERN) then
                return false, "git-tracking.json: platform_authors key '" .. tostring(plat)
                    .. "' must match [a-z0-9_-]+"
            end
            if not is_string(author) then
                return false, "git-tracking.json: platform_authors[" .. plat .. "] must be a string"
            end
        end
    end
    if data.repos == nil then return true, nil end
    if type(data.repos) ~= "table" then
        return false, "git-tracking.json: repos must be an array"
    end
    for i, r in ipairs(data.repos) do
        if type(r) ~= "table" then
            return false, "git-tracking.json: repos[" .. i .. "] must be an object"
        end
        if not is_nonempty_string(r.path) then
            return false, "git-tracking.json: repos[" .. i .. "].path required (non-empty string)"
        end
        if r.author ~= nil and not is_string(r.author) then
            return false, "git-tracking.json: repos[" .. i .. "].author must be a string"
        end
        if r.platform ~= nil and r.platform ~= "" then
            if not is_string(r.platform) or not r.platform:match(PLATFORM_PATTERN) then
                return false, "git-tracking.json: repos[" .. i ..
                    "].platform must match [a-z0-9_-]+ (e.g. forgejo, github, gitlab)"
            end
        end
        if r.alias ~= nil and not is_string(r.alias) then
            return false, "git-tracking.json: repos[" .. i .. "].alias must be a string"
        end
    end
    return true, nil
end

-- Validate openrouter-free.json: { pool: [":free" ids], default: ":free" id | "" }
-- pool = ordered fallback models injected for :free requests (OpenRouter caps at 3);
-- default = the :free model a model-less / non-:free request is rewritten to.
local function is_free_model(v)
    return type(v) == "string" and v ~= "" and v:sub(-5) == ":free"
end

-- Validate an ordered array of :free model ids (max 3, no dups). label is used
-- in error messages. Returns (ok, err).
local function validate_free_array(arr, label)
    if type(arr) ~= "table" then
        return false, "openrouter-free.json: " .. label .. " must be an array"
    end
    if #arr > 3 then
        return false, "openrouter-free.json: " .. label
            .. " may hold at most 3 models (OpenRouter caps the models array)"
    end
    local seen = {}
    for i, m in ipairs(arr) do
        if not is_free_model(m) then
            return false, "openrouter-free.json: " .. label .. "[" .. i
                .. "] must be a non-empty ':free' model id"
        end
        if seen[m] then
            return false, "openrouter-free.json: " .. label .. "[" .. i
                .. "] duplicate '" .. tostring(m) .. "'"
        end
        seen[m] = true
    end
    return true, nil
end

function _M.validate_openrouter_free(data)
    if not is_table(data) then
        return false, "openrouter-free.json: root must be an object"
    end
    if data.pool ~= nil then
        local ok, err = validate_free_array(data.pool, "pool")
        if not ok then return false, err end
    end
    if data.default ~= nil and data.default ~= "" and not is_free_model(data.default) then
        return false, "openrouter-free.json: default must be a ':free' model id (or empty)"
    end
    -- routes: { <category> = [":free" ids], ... }. Category keys are lowercase
    -- words; each value is a :free array (the ordered model list for that
    -- request category, used by handler.lua's capability router).
    if data.routes ~= nil then
        if type(data.routes) ~= "table" then
            return false, "openrouter-free.json: routes must be an object"
        end
        for cat, arr in pairs(data.routes) do
            if type(cat) ~= "string" or not cat:match("^[a-z][a-z0-9_]*$") then
                return false, "openrouter-free.json: routes key '" .. tostring(cat)
                    .. "' must be a lowercase category name ([a-z][a-z0-9_]*)"
            end
            local ok, err = validate_free_array(arr, "routes." .. cat)
            if not ok then return false, err end
        end
    end
    if data.long_context_threshold ~= nil and not is_pos_int(data.long_context_threshold) then
        return false, "openrouter-free.json: long_context_threshold must be a positive integer"
    end
    -- Account-wide free-tier request caps (visibility only — the proxy never
    -- enforces them, it only mirrors OpenRouter's own 429s; see handler.lua).
    if data.daily_limit ~= nil and not is_pos_int(data.daily_limit) then
        return false, "openrouter-free.json: daily_limit must be a positive integer"
    end
    if data.minute_limit ~= nil and not is_pos_int(data.minute_limit) then
        return false, "openrouter-free.json: minute_limit must be a positive integer"
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

    -- All config roots must be JSON objects. A root array (incl. empty `[]`, which
    -- cjson decodes to an empty table indistinguishable from `{}`) would otherwise
    -- pass the is_table root check and validate as "valid-empty". Reject it up front.
    if raw:match("^%s*%[") then
        return nil, path .. ": root must be a JSON object, not an array"
    end

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
