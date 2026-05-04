-- providers/omlx.lua: local OMLX (https://github.com/jundot/omlx) — an
-- OpenAI-compatible local LLM server. Loopback URL by default (127.0.0.1
-- inside the proxy container's network would be the proxy itself; use
-- host.docker.internal to reach the host where omlx listens, or override
-- with OMLX_URL when running omlx in a sibling container).
local openai_compat = require "providers.openai_compatible"
local openai_format = require "providers.openai_format"

local _M = {}

_M.upstream_url             = os.getenv("OMLX_URL") or "http://host.docker.internal:8000"
_M.stream_options_usage     = true
_M.build_headers            = openai_compat.build_headers   -- Bearer token; omlx accepts dummy if no auth
_M.extract_tokens           = openai_compat.extract_tokens
_M.extract_tokens_streaming = openai_format.extract_tokens_streaming

return _M
