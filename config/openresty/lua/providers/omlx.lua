-- providers/omlx.lua: local oMLX (https://github.com/jundot/omlx) — drop-in
-- Anthropic API on /v1/messages (also exposes OpenAI-compatible /v1/chat/completions).
-- Default URL targets the Mac host from inside the proxy container; override
-- with OMLX_URL if oMLX runs as a sibling container.
--
-- gateii routes Claude Code traffic, which always speaks /v1/messages → we
-- use Anthropic-style token extraction. Bearer auth (built by openai_compat)
-- works because oMLX accepts both Authorization: Bearer and x-api-key.
--
-- oMLX usage quirk: /v1/messages responses report input_tokens=0 with the
-- actual prompt size in cache_creation_input_tokens. anthropic.extract_tokens
-- already returns those as separate fields; gateii's tracking sums them.
local openai_compat = require "providers.openai_compatible"
local anthropic     = require "providers.anthropic"

local _M = {}

_M.upstream_url             = os.getenv("OMLX_URL") or "http://host.docker.internal:8000"
_M.build_headers            = openai_compat.build_headers
_M.extract_tokens           = anthropic.extract_tokens
_M.extract_tokens_streaming = anthropic.extract_tokens_streaming

return _M
