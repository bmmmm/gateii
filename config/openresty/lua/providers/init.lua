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

-- SSRF defense-in-depth: reject any provider whose upstream is not HTTPS,
-- with the explicit exception of loopback / Docker-host loopback for local
-- model servers (omlx, ollama, etc.). You can't SSRF yourself: the attack
-- surface is "force the proxy to call an internal service it shouldn't",
-- which doesn't apply when the destination IS expected to be local.
local function is_safe_upstream(url)
    if type(url) ~= "string" then return false end
    if url:sub(1, 8) == "https://" then return true end
    if url:sub(1, 16) == "http://127.0.0.1"           then return true end
    if url:sub(1, 16) == "http://localhost"           then return true end
    if url:sub(1, 25) == "http://host.docker.internal" then return true end
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
