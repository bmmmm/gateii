-- providers/openai.lua: OpenAI provider
-- TODO: set OPENAI_API_KEY in .env and docker-compose
local openai_compat = require "providers.openai_compatible"
local openai_format = require "providers.openai_format"

local _M = {}

_M.upstream_url             = "https://api.openai.com"
_M.stream_options_usage     = true
_M.build_headers            = openai_compat.build_headers
_M.extract_tokens           = openai_compat.extract_tokens
_M.extract_tokens_streaming = openai_format.extract_tokens_streaming

return _M
