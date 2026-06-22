-- providers/init.lua: provider registry
-- To add a new provider:
--   1. Create providers/<name>.lua with the required interface
--   2. Add one line to the registry table below
local _M = {}

local registry = {
    anthropic  = require "providers.anthropic",
    openai     = require "providers.openai",
    openrouter = require "providers.openrouter",
    omlx       = require "providers.omlx",
}

-- Internal providers point at loopback / Docker-host-loopback model servers
-- (oMLX, ollama, …). They must never be selectable via the CLIENT-supplied
-- x-provider header (the passthrough fallback path) — otherwise a client with
-- a valid passthrough key could POST x-provider:omlx and reach the internal
-- oMLX control endpoints, bypassing ADMIN_TOKEN (SSRF / RAM-DoS). They remain
-- reachable through a trusted per-user pin (ngx.ctx.upstream_provider). Set on
-- the provider module so handler.lua can check provider.internal directly.
local internal_providers = { omlx = true }
for name, p in pairs(registry) do
    if p and internal_providers[name] then
        p.internal = true
    end
end

-- SSRF defense-in-depth: reject any provider whose upstream is not HTTPS,
-- with the explicit exception of loopback / Docker-host loopback for local
-- model servers (omlx, ollama, etc.). You can't SSRF yourself: the attack
-- surface is "force the proxy to call an internal service it shouldn't",
-- which doesn't apply when the destination IS expected to be local.
local function is_safe_upstream(url)
    if type(url) ~= "string" then return false end
    if url:sub(1, 8) == "https://" then return true end
    -- For local http:// endpoints the character immediately after the host must
    -- be ":", "/" or end-of-string. A bare prefix match would accept
    -- http://127.0.0.1.evil.com — the boundary check closes that.
    local local_prefixes = {
        "http://127.0.0.1",
        "http://localhost",
        "http://host.docker.internal",
    }
    for _, prefix in ipairs(local_prefixes) do
        if url:sub(1, #prefix) == prefix then
            local next = url:sub(#prefix + 1, #prefix + 1)
            if next == "" or next == "/" or next == ":" then return true end
        end
    end
    return false
end
for name, p in pairs(registry) do
    if not is_safe_upstream(p and p.upstream_url) then
        error("provider '" .. name .. "' has invalid upstream_url (must be https:// or loopback): "
              .. tostring(p and p.upstream_url))
    end
end

function _M.get(name)
    return registry[name]  -- nil if unknown
end

return _M
