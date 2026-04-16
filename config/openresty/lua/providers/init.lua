-- providers/init.lua: provider registry
-- To add a new provider:
--   1. Create providers/<name>.lua with the required interface
--   2. Add one line to the registry table below
local _M = {}

local registry = {
    anthropic  = require "providers.anthropic",
    openai     = require "providers.openai",
    openrouter = require "providers.openrouter",
}

-- SSRF defense-in-depth: reject any provider whose upstream is not HTTPS.
-- Fails worker startup so misconfiguration is loud, not silent.
for name, p in pairs(registry) do
    local url = p and p.upstream_url
    if type(url) ~= "string" or url:sub(1, 8) ~= "https://" then
        error("provider '" .. name .. "' has invalid upstream_url (must start with https://): "
              .. tostring(url))
    end
end

function _M.get(name)
    return registry[name]  -- nil if unknown
end

return _M
