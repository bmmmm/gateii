-- handler.lua: proxy + token tracking
local cjson    = require "cjson.safe"
local http     = require "resty.http"
local providers = require "providers.init"
local tracking  = require "tracking"
local circuit_breaker = require "circuit_breaker"

-- Request ID is set by auth.lua into ngx.ctx.request_id. Declare at top of
-- chunk so the closures below capture it as an upvalue — a local declared
-- later in the chunk would not be visible to functions defined above it.
local rid = ngx.ctx.request_id or "-"

-- Returns the upstream Content-Encoding lowercased, or nil if absent. A header
-- table may carry a multi-value array (rare); take the first entry.
local function response_content_encoding(res)
    local h = res and res.headers
    if not h then return nil end
    local ce = h["Content-Encoding"] or h["content-encoding"]
    if type(ce) == "table" then ce = ce[1] end
    if type(ce) ~= "string" then return nil end
    return ce:lower():match("^%s*(.-)%s*$")
end

-- Skip token extraction when the upstream sent a non-identity Content-Encoding.
-- The body is forwarded verbatim (correct), but our extractors parse plaintext
-- JSON/SSE — running them on gzip/br would yield 0 tokens. We do NOT decompress
-- in-proxy; defense-in-depth only. Warned once per worker to avoid log spam.
local encoding_warned = false
local function tokens_extractable(res)
    local ce = response_content_encoding(res)
    if ce == nil or ce == "" or ce == "identity" then return true end
    if not encoding_warned then
        encoding_warned = true
        ngx.log(ngx.WARN, "[rid=", rid, "] upstream Content-Encoding '", ce,
                "' is non-identity — skipping token extraction (tokens recorded as 0)")
    end
    return false
end

local function track_rl_window(res)
    if not res.headers then return end
    local h = res.headers
    -- Anthropic unified rate limit headers (replaced old anthropic-ratelimit-tokens-* headers)
    local util_5h  = tonumber(h["anthropic-ratelimit-unified-5h-utilization"])
    local reset_5h = tonumber(h["anthropic-ratelimit-unified-5h-reset"])  -- Unix timestamp
    local util_7d  = tonumber(h["anthropic-ratelimit-unified-7d-utilization"])
    if util_5h == nil or reset_5h == nil then return end

    -- Convert Unix timestamp → RFC3339 (compatible with auto-reset timer and metrics.lua parser)
    local reset_ts = os.date("!%Y-%m-%dT%H:%M:%SZ", reset_5h)

    tracking.set_rate_limit_5h_utilization(util_5h)
    if util_7d ~= nil then tracking.set_rate_limit_7d_utilization(util_7d) end

    -- 7d window reset time (separate from 5h)
    local reset_7d = tonumber(h["anthropic-ratelimit-unified-7d-reset"])
    if reset_7d ~= nil then
        tracking.set_rate_limit_7d_reset(os.date("!%Y-%m-%dT%H:%M:%SZ", reset_7d))
    end

    -- Fallback capacity: fraction of extra tokens available after primary 5h limit is hit
    local fallback_pct = tonumber(h["anthropic-ratelimit-unified-fallback-percentage"])
    if fallback_pct ~= nil then
        tracking.set_rate_limit_fallback_pct(fallback_pct)
    end

    local cd = ngx.shared.counters
    -- Compute absolute remaining tokens using tokens_window_limit from shared dict
    local tokens_limit = tonumber(cd:get("tokens_window_limit"))
    if tokens_limit then
        local remaining = math.floor(tokens_limit * (1.0 - util_5h))
        local prev_reset = tracking.get_rate_limit_reset()
        if prev_reset and prev_reset ~= reset_ts then
            -- Claim the reset atomically so only one worker records the expiry
            -- snapshot. add() succeeds for the first caller and returns "exists"
            -- for the rest, collapsing concurrent observers of the same reset.
            local claimed = cd:add("ratelimit_expiry_claim|" .. reset_ts, 1, 600)
            if claimed then
                local old_remaining = tonumber(cd:get("ratelimit_remaining")) or 0
                tracking.set_rate_limit_tokens_expired(old_remaining)
                ngx.log(ngx.INFO, "[rid=", rid, "] rate limit window reset: ", old_remaining, " tokens expired")
            end
        end
        tracking.set_rate_limit_remaining(remaining)
    end
    tracking.set_rate_limit_reset(reset_ts)
end

local function track_rl_429(res, u, m, pname)
    local h = res.headers or {}
    -- Derive which limit was hit from the same unified headers sent on every response.
    -- Neither a "representative-claim" nor a generic "-unified-reset" header exists;
    -- Anthropic sends per-window utilization/reset headers (same as on 200 responses).
    local util_5h  = tonumber(h["anthropic-ratelimit-unified-5h-utilization"])
    local reset_5h = tonumber(h["anthropic-ratelimit-unified-5h-reset"])
    local util_7d  = tonumber(h["anthropic-ratelimit-unified-7d-utilization"])
    local reset_7d = tonumber(h["anthropic-ratelimit-unified-7d-reset"])

    -- Which window is exhausted? Higher utilization wins; default "5h" when ambiguous.
    local limit_type = "unknown"
    if util_5h or util_7d then
        local u5 = util_5h or 0
        local u7 = util_7d or 0
        limit_type = (u7 > u5) and "7d" or "5h"
    end

    -- Seconds until the exhausted window resets; fall back to Retry-After header.
    local retry_after = tonumber(h["retry-after"]) or 0
    if limit_type == "7d" and reset_7d then
        retry_after = math.max(0, reset_7d - ngx.time())
    elseif reset_5h then
        retry_after = math.max(0, reset_5h - ngx.time())
    end

    local hit_tokens = 0
    local cd = ngx.shared.counters
    if cd and u and m then
        local base = u .. "|" .. pname .. "|" .. m .. "|"
        for _, t in ipairs({"input", "output", "cache_creation", "cache_read"}) do
            local v = cd:get(base .. t)
            if v then hit_tokens = hit_tokens + v end
        end
    end
    ngx.log(ngx.INFO, "[rid=", rid, "] rl_429 user=", tostring(u),
            " model=", tostring(m), " limit=", limit_type,
            " wait=", retry_after, "s tokens=", hit_tokens,
            " util_5h=", tostring(util_5h), " util_7d=", tostring(util_7d))
    tracking.set_rate_limit_wait(u or "unknown", m or "unknown", limit_type, retry_after)
    tracking.set_rate_limit_tokens_at_hit(u or "unknown", m or "unknown", limit_type, hit_tokens)
end

-- Read body — with temp-file fallback for concurrent load (body buffered to disk)
local body_str = ngx.req.get_body_data()
if not body_str then
    local body_file = ngx.req.get_body_file()
    if body_file then
        local f, open_err = io.open(body_file, "rb")
        if not f then
            ngx.log(ngx.ERR, "[rid=", rid, "] handler: cannot open body file: ", open_err)
        else
            local ok, result = pcall(f.read, f, "*a")
            f:close()
            if not ok then
                ngx.log(ngx.ERR, "[rid=", rid, "] handler: cannot read body file: ", result)
            else
                body_str = result
            end
        end
    end
end
if not body_str or body_str == "" then
    ngx.status = 400
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Empty request body — send a JSON payload"}')
    return
end

local body_obj, parse_err = cjson.decode(body_str)
if not body_obj then
    ngx.log(ngx.WARN, "[rid=", rid, "] request JSON parse error: ", parse_err)
    ngx.status = 400
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Invalid JSON — check your request body"}')
    return
end

-- Get request headers once — reused for both provider selection and header forwarding
local req_headers = ngx.req.get_headers()

-- Resolve provider. Prefer the per-user pin from auth.lua (ngx.ctx.upstream_provider),
-- which is trusted apikey config. The x-provider header is a CLIENT-supplied fallback
-- (passthrough mode + ad-hoc testing) — track which source won so we can reject
-- client selection of internal/loopback providers below.
local trusted_provider = ngx.ctx.upstream_provider
local provider_name = trusted_provider or req_headers["x-provider"] or "anthropic"
local provider_from_client = (trusted_provider == nil) and (req_headers["x-provider"] ~= nil)
local provider = providers.get(provider_name)
if not provider then
    ngx.status = 400
    ngx.header["Content-Type"] = "application/json"
    -- Don't reflect raw header value — could contain JSON-breaking characters
    ngx.say('{"error":"Unknown provider — available: anthropic, openai, openrouter"}')
    return
end
-- Internal providers (omlx, …) only via the trusted per-user pin. A client must
-- not be able to select them through x-provider — that would route passthrough
-- traffic at the internal loopback model server, bypassing ADMIN_TOKEN.
if provider.internal and provider_from_client then
    ngx.log(ngx.WARN, "[rid=", rid, "] client x-provider selected internal provider, refused: ", provider_name)
    ngx.status = 400
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"provider not selectable"}')
    return
end
if not provider.upstream_url or provider.upstream_url == "" then
    ngx.log(ngx.ERR, "[rid=", rid, "] provider has no upstream_url: ", provider_name)
    ngx.status = 500
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Internal configuration error"}')
    return
end

local is_streaming = body_obj.stream == true
local user = ngx.ctx.user
-- Trim model name (whitespace in model names would break counter keys).
-- model is client-controlled JSON: guard the type before string methods —
-- a truthy non-string (number/table/bool) would slip past `or "unknown"` and
-- raise an uncaught error on :match (mirrors the type guards at output_config
-- .effort below and free_fallback further down).
local model = body_obj.model
if type(model) == "string" then
    model = model:match("^%s*(.-)%s*$")
else
    model = "unknown"
end

-- Opus 4.7 output_config.effort (low|medium|high|xhigh|max) — "none" if unset
local request_effort = "none"
if type(body_obj.output_config) == "table"
   and type(body_obj.output_config.effort) == "string" then
    request_effort = body_obj.output_config.effort
end

-- Vision detection: one pass over messages[].content[] looking for image blocks.
-- Usage tokens from Anthropic aren't split by modality, so we only track the boolean.
local request_has_vision = false
if type(body_obj.messages) == "table" then
    for _, msg in ipairs(body_obj.messages) do
        if type(msg.content) == "table" then
            for _, block in ipairs(msg.content) do
                if type(block) == "table" and block.type == "image" then
                    request_has_vision = true
                    break
                end
            end
        end
        if request_has_vision then break end
    end
end

-- Inject stream_options so OpenAI-format providers return usage in streaming responses
local body_mutated = false
if is_streaming and provider.stream_options_usage then
    body_obj.stream_options = body_obj.stream_options or {}
    body_obj.stream_options.include_usage = true
    body_mutated = true
end

-- OpenRouter free-tier auto-fallback: if the requested model ends with ":free"
-- and the caller didn't already supply a `models` array, inject one from the
-- provider's free_fallback_pool. OR then retries the next entry on upstream
-- 429/provider errors, transparently to the client.
if provider.free_fallback_pool and type(body_obj.models) ~= "table"
   and type(body_obj.model) == "string" and body_obj.model:sub(-5) == ":free" then
    -- OpenRouter caps the `models` array at 3 entries; truncate silently.
    local MAX_FALLBACK = 3
    local seen = { [body_obj.model] = true }
    local pool = { body_obj.model }
    for _, m in ipairs(provider.free_fallback_pool) do
        if #pool >= MAX_FALLBACK then break end
        if not seen[m] then
            seen[m] = true
            pool[#pool + 1] = m
        end
    end
    if #pool > 1 then
        body_obj.models = pool
        body_mutated = true
        ngx.log(ngx.INFO, "[rid=", rid, "] openrouter free-pool fallback: ",
                table.concat(pool, ","))
    end
end

if body_mutated then
    body_str = cjson.encode(body_obj)
end

-- Build upstream request
-- In passthrough mode, ngx.ctx.upstream_key carries the client's own API key
local upstream_headers = provider.build_headers(ngx.ctx.upstream_key, ngx.ctx.upstream_auth_type)

-- Forward all anthropic-* headers (beta, version overrides, browser-access, etc.),
-- x-stainless-* SDK telemetry headers, and user-agent to upstream.
-- Auth headers (x-api-key, authorization) are handled by build_headers above.
-- Use normalized lowercase keys to prevent duplicate headers with mixed casing.
for name, value in pairs(req_headers) do
    local lower = name:lower()
    -- string.sub prefix checks avoid the regex engine for the common case
    local forwardable = (lower:sub(1, 10) == "anthropic-" and lower ~= "anthropic-version")
        or lower:sub(1, 12) == "x-stainless-" or lower == "user-agent"
    if forwardable then
        -- Strip CRLF to prevent header injection into upstream request
        if type(value) == "string" then
            upstream_headers[lower] = value:gsub("[\r\n]", "")
        elseif type(value) == "table" then
            local cleaned = {}
            for i, v in ipairs(value) do
                cleaned[i] = tostring(v):gsub("[\r\n]", "")
            end
            upstream_headers[lower] = cleaned
        end
    end
end
local upstream_url = provider.upstream_url .. ngx.var.request_uri

-- Non-streaming: direct proxy
if not is_streaming then
    local cb_ok, cb_reason = circuit_breaker.allow_request(provider_name)
    if not cb_ok then
        ngx.log(ngx.WARN, "[rid=", rid, "] circuit breaker blocked ", provider_name, " (", cb_reason, ")")
        ngx.status = 503
        ngx.header["Content-Type"] = "application/json"
        ngx.header["Retry-After"]  = "30"
        ngx.say('{"error":"Upstream temporarily unavailable — retry in 30s"}')
        pcall(tracking.record, user, provider_name, model, 0, 0,
              { latency_ms = 0, status = 503 })
        return
    end

    local httpc = http.new()
    httpc:set_timeout(60000)

    local t0 = ngx.now()
    local res, proxy_err = httpc:request_uri(upstream_url, {
        method  = ngx.var.request_method,
        body    = body_str,
        headers = upstream_headers,
        ssl_verify = true,
        keepalive_timeout = 60000,  -- 60s idle
        keepalive_pool    = 32,     -- pool size per worker
    })
    local latency_ms = (ngx.now() - t0) * 1000

    if not res then
        ngx.log(ngx.ERR, "[rid=", rid, "] upstream error (user=", user, " model=", model, "): ", proxy_err)
        circuit_breaker.record(provider_name, nil, proxy_err)
        ngx.status = 502
        ngx.header["Content-Type"] = "application/json"
        ngx.say('{"error":"Upstream request failed — check logs for details"}')
        pcall(tracking.record, user, provider_name, model, 0, 0,
              { latency_ms = latency_ms, status = 502 })
        return
    end

    local response_body = res.body
    ngx.status = res.status
    for k, v in pairs(res.headers) do
        local lk = k:lower()
        if lk:sub(1, 10) == "anthropic-" or lk == "content-type"
           or lk == "content-encoding" or lk == "x-request-id" then
            ngx.header[k] = v
        end
    end

    local input_tokens, output_tokens, stop_reason, cache_creation, cache_read = 0, 0, nil, 0, 0
    if res.status == 200 then
        if tokens_extractable(res) then
            input_tokens, output_tokens, stop_reason, cache_creation, cache_read = provider.extract_tokens(response_body)
        end
        track_rl_window(res)
    end
    if res.status == 429 then track_rl_429(res, user, model, provider_name) end

    ngx.print(response_body)
    ngx.flush(true)  -- send to client before tracking write
    circuit_breaker.record(provider_name, res.status, nil)
    local _ok, _err = pcall(tracking.record, user, provider_name, model, input_tokens, output_tokens,
          { latency_ms = latency_ms, status = res.status, stop_reason = stop_reason,
            cache_creation = cache_creation, cache_read = cache_read })
    if not _ok then ngx.log(ngx.WARN, "[rid=", rid, "] tracking.record failed: ", tostring(_err)) end
    _ok, _err = pcall(tracking.record_effort,   user, provider_name, model, request_effort,     input_tokens, output_tokens)
    if not _ok then ngx.log(ngx.WARN, "[rid=", rid, "] tracking.record_effort failed: ", tostring(_err)) end
    _ok, _err = pcall(tracking.record_modality, user, provider_name, model, request_has_vision, input_tokens, output_tokens)
    if not _ok then ngx.log(ngx.WARN, "[rid=", rid, "] tracking.record_modality failed: ", tostring(_err)) end
    return
end

-- Streaming path: proxy directly
local cb_ok, cb_reason = circuit_breaker.allow_request(provider_name)
if not cb_ok then
    ngx.log(ngx.WARN, "[rid=", rid, "] circuit breaker blocked ", provider_name, " (", cb_reason, ")")
    ngx.status = 503
    ngx.header["Content-Type"] = "application/json"
    ngx.header["Retry-After"]  = "30"
    ngx.say('{"error":"Upstream temporarily unavailable — retry in 30s"}')
    pcall(tracking.record, user, provider_name, model, 0, 0,
          { latency_ms = 0, status = 503 })
    return
end

local httpc = http.new()
httpc:set_timeouts(10000, 30000, 120000)  -- connect 10s, send 30s, read 120s per chunk
local t0_stream = ngx.now()

local parsed_uri, parse_err2 = httpc:parse_uri(upstream_url, false)
if not parsed_uri then
    ngx.log(ngx.ERR, "[rid=", rid, "] streaming URI parse error: ", parse_err2)
    httpc:close()
    ngx.status = 500
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Internal proxy error"}')
    pcall(tracking.record, user, provider_name, model, 0, 0,
          { latency_ms = 0, status = 500 })
    return
end

local scheme, host, port, path = unpack(parsed_uri)
local ok, conn_err = httpc:connect({
    scheme          = scheme,
    host            = host,
    port            = port,
    ssl_server_name = host,
    ssl_verify      = true,
})
if not ok then
    ngx.log(ngx.ERR, "[rid=", rid, "] streaming connect error (user=", user, "): ", conn_err)
    circuit_breaker.record(provider_name, nil, conn_err)
    httpc:close()
    ngx.status = 502
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Failed to connect to upstream"}')
    pcall(tracking.record, user, provider_name, model, 0, 0,
          { latency_ms = (ngx.now() - t0_stream) * 1000, status = 502 })
    return
end

local res, req_err = httpc:request({
    method  = ngx.var.request_method,
    path    = path,
    body    = body_str,
    headers = upstream_headers,
})

if not res then
    ngx.log(ngx.ERR, "[rid=", rid, "] streaming upstream error (user=", user, "): ", req_err)
    circuit_breaker.record(provider_name, nil, req_err)
    httpc:close()
    ngx.status = 502
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Upstream streaming request failed"}')
    pcall(tracking.record, user, provider_name, model, 0, 0,
          { latency_ms = (ngx.now() - t0_stream) * 1000, status = 502 })
    return
end

ngx.status = res.status
for k, v in pairs(res.headers) do
    local lk = k:lower()
    if lk:sub(1, 10) == "anthropic-" or lk == "content-type"
       or lk == "content-encoding" or lk == "x-request-id" then
        ngx.header[k] = v
    end
end

-- Accumulate only what the SSE parser needs: the head of the stream (Anthropic
-- message_start lives here) + a rolling tail (message_delta / OpenAI final-usage
-- chunk). Avoids buffering the entire response body, which can be hundreds of KB
-- on long streams.
--
-- The head keeps growing into first_parts until it holds a complete SSE event
-- (terminated by a "\n\n" boundary) — only then do we freeze it and switch to
-- the rolling tail. Freezing at exactly reader(8192) #1 would lose message_start
-- when it spans chunk #1 → #2, and the front-trimming tail could later evict it.
local TAIL_BYTES = 32 * 1024
local first_parts = {}      -- head chunks until a full SSE event boundary is seen
local first_done = false    -- head sealed once it contains "\n\n"
local first_chunk           -- sealed head, concatenated
local tail = {}
local tail_bytes = 0
local had_read_err = false
local reader = res.body_reader
if not reader then
    ngx.log(ngx.WARN, "[rid=", rid, "] no body_reader (status=", res.status, ") — skipping stream")
    httpc:set_keepalive(60000, 32)
    goto done_streaming
end
repeat
    local chunk, read_err = reader(8192)
    if read_err then
        ngx.log(ngx.ERR, "[rid=", rid, "] streaming read error (user=", user, "): ", read_err)
        had_read_err = true
        break
    end
    if chunk then
        ngx.print(chunk)
        ngx.flush(true)
        if not first_done then
            first_parts[#first_parts+1] = chunk
            -- Seal the head once it spans a full SSE event boundary.
            if chunk:find("\n\n", 1, true) then
                first_chunk = table.concat(first_parts)
                first_done = true
            end
        else
            tail[#tail+1] = chunk
            tail_bytes = tail_bytes + #chunk
            while tail_bytes > TAIL_BYTES and #tail > 1 do
                tail_bytes = tail_bytes - #tail[1]
                table.remove(tail, 1)
            end
        end
    end
until not chunk
-- Stream ended before any "\n\n" boundary (single short/partial event): seal
-- whatever head we collected so the parser still gets the message_start bytes.
if not first_done and #first_parts > 0 then
    first_chunk = table.concat(first_parts)
end
if had_read_err then
    httpc:close()
else
    httpc:set_keepalive(60000, 32)
end

::done_streaming::
-- Parse SSE events for token tracking — delegate to provider-specific parser.
-- Concat first chunk with tail; middle of stream (all content deltas) is discarded
-- since it carries no token-accounting data for any supported provider.
local input_tokens, output_tokens, stop_reason = 0, 0, nil
local cache_creation, cache_read = 0, 0
if res.status == 200 and provider.extract_tokens_streaming and first_chunk
   and tokens_extractable(res) then
    local body = #tail > 0 and (first_chunk .. table.concat(tail)) or first_chunk
    input_tokens, output_tokens, stop_reason, cache_creation, cache_read =
        provider.extract_tokens_streaming(body)
end

if res.status == 200 then track_rl_window(res) end
if res.status == 429 then track_rl_429(res, user, model, provider_name) end

-- A mid-stream read error after headers were already committed leaves the client
-- with a truncated SSE body. We can't change the HTTP status (it's flushed), but
-- record a synthetic 5xx so tracking's error/5xx counters fire instead of logging
-- the failure as a clean 200. circuit_breaker.record keeps the real status — its
-- "read_error" reason already accounts for the failure.
local track_status = had_read_err and 599 or res.status

circuit_breaker.record(provider_name, res.status, had_read_err and "read_error" or nil)
local _ok, _err = pcall(tracking.record, user, provider_name, model, input_tokens, output_tokens,
      { latency_ms = (ngx.now() - t0_stream) * 1000, status = track_status, stop_reason = stop_reason,
        cache_creation = cache_creation, cache_read = cache_read })
if not _ok then ngx.log(ngx.WARN, "[rid=", rid, "] tracking.record failed: ", tostring(_err)) end
_ok, _err = pcall(tracking.record_effort,   user, provider_name, model, request_effort,     input_tokens, output_tokens)
if not _ok then ngx.log(ngx.WARN, "[rid=", rid, "] tracking.record_effort failed: ", tostring(_err)) end
_ok, _err = pcall(tracking.record_modality, user, provider_name, model, request_has_vision, input_tokens, output_tokens)
if not _ok then ngx.log(ngx.WARN, "[rid=", rid, "] tracking.record_modality failed: ", tostring(_err)) end

-- Terminate the response as broken (no clean chunked EOF) so the client can tell
-- the stream was truncated rather than completed. Done last, after tracking.
if had_read_err then
    ngx.exit(ngx.ERROR)
end
