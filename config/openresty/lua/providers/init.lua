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

function _M.get(name)
    return registry[name]  -- nil if unknown
end

return _M
