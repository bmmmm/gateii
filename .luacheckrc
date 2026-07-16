-- luacheck configuration for gateii (OpenResty/LuaJIT project)

-- OpenResty/LuaJIT globals (not in standard Lua 5.1)
globals = {
    "ngx",
    "cjson",
}

-- OpenResty subglobals (accessed via ngx.*)
allow_defined_top = true

-- Configuration
max_line_length = 140
unused = false
unused_args = false

-- Ignore idiomatic empty skip-branches in dispatch chains (W542): several
-- `if key:sub(...) then -- skip` guards read clearer than an inverted condition
-- (metrics.lua day|-key skip, anthropic.lua SSE-comment skip).
ignore = {
    "542",  -- empty if branch
}

-- Exclude directories. resty/ is vendored lua-resty-http — not our code, and its
-- 20 style warnings were silently breaking CI (luacheck exits 1 on any warning).
exclude_files = {
    "spec/",
    "config/openresty/lua/resty/",
}
