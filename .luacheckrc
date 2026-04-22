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

-- Exclude directories
exclude_files = {
    "spec/",
}
