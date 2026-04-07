-- handler.lua: proxy + token tracking
local cjson    = require "cjson.safe"
local http     = require "resty.http"
local providers = require "providers.init"
local tracking  = require "tracking"

local function parse_rfc3339_offset(s)
    -- Returns seconds until the given RFC3339 timestamp, relative to now.
    -- Handles "2026-04-07T15:30:00Z" format (UTC only, ignores timezone offset).
    if not s then return nil end
    local y, mo, d, h, mi, se = s:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    local months = {0,31,59,90,120,151,181,212,243,273,304,334}
    local days = (tonumber(y) - 1970) * 365 + math.floor((tonumber(y) - 1969) / 4)
              + (months[tonumber(mo)] or 0) + tonumber(d) - 1
    local epoch = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(se)
    return epoch - ngx.time()
end

local function track_rl_window(res)
    local rl_remaining = tonumber(res.headers and res.headers["anthropic-ratelimit-tokens-remaining"])
    local rl_reset     = res.headers and res.headers["anthropic-ratelimit-tokens-reset"]
    if rl_remaining == nil then return end
    local prev_reset = tracking.get_rate_limit_reset()
    if prev_reset and rl_reset and prev_reset ~= rl_reset then
        local old_remaining = tonumber(ngx.shared.counters:get("ratelimit_remaining")) or 0
        tracking.set_rate_limit_tokens_expired(old_remaining)
        ngx.log(ngx.INFO, "rate limit window reset: ", old_remaining, " tokens expired")
    end
    if rl_reset then tracking.set_rate_limit_reset(rl_reset) end
    tracking.set_rate_limit_remaining(rl_remaining)
end

local function track_rl_429(res, u, m, pname)
    local reset_header = res.headers and res.headers["anthropic-ratelimit-tokens-reset"]
    local limit_type = "unknown"
    if reset_header then
        local offset = parse_rfc3339_offset(reset_header)
        if offset then limit_type = (offset <= 21600) and "5h" or "weekly" end
    end
    local retry_after = tonumber(res.headers and res.headers["retry-after"]) or 0
    local hit_tokens = 0
    local cd = ngx.shared.counters
    if cd and u and m then
        for _, t in ipairs({"input", "output", "cache_creation", "cache_read"}) do
            local v = cd:get(u .. "|" .. pname .. "|" .. m .. "|" .. t)
            if v then hit_tokens = hit_tokens + v end
        end
    end
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
            ngx.log(ngx.ERR, "handler: cannot open body file: ", open_err)
        else
            local ok, result = pcall(f.read, f, "*a")
            f:close()
            if not ok then
                ngx.log(ngx.ERR, "handler: cannot read body file: ", result)
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
    ngx.log(ngx.WARN, "request JSON parse error: ", parse_err)
    ngx.status = 400
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Invalid JSON — check your request body"}')
    return
end

-- Resolve provider (whitelist enforced by providers.get)
local provider_name = ngx.req.get_headers()["X-Provider"] or "anthropic"
local provider = providers.get(provider_name)
if not provider then
    ngx.status = 400
    ngx.header["Content-Type"] = "application/json"
    -- Don't reflect raw header value — could contain JSON-breaking characters
    ngx.say('{"error":"Unknown provider — available: anthropic, openai, openrouter"}')
    return
end
if not provider.upstream_url or provider.upstream_url == "" then
    ngx.log(ngx.ERR, "provider has no upstream_url: ", provider_name)
    ngx.status = 500
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Internal configuration error"}')
    return
end

local is_streaming = body_obj.stream == true
local user = ngx.ctx.user
-- Trim model name (whitespace in model names would break counter keys)
local model = (body_obj.model or "unknown"):match("^%s*(.-)%s*$")

-- Inject stream_options so OpenAI-format providers return usage in streaming responses
if is_streaming and provider.stream_options_usage then
    body_obj.stream_options = body_obj.stream_options or {}
    body_obj.stream_options.include_usage = true
    body_str = cjson.encode(body_obj)
end

-- Build upstream request
-- In passthrough mode, ngx.ctx.upstream_key carries the client's own API key
local upstream_headers = provider.build_headers(ngx.ctx.upstream_key, ngx.ctx.upstream_auth_type)

-- Forward all anthropic-* headers (beta, version overrides, browser-access, etc.),
-- x-stainless-* SDK telemetry headers, and user-agent to upstream.
-- Auth headers (x-api-key, authorization) are handled by build_headers above.
-- Use normalized lowercase keys to prevent duplicate headers with mixed casing.
local req_headers = ngx.req.get_headers()
for name, value in pairs(req_headers) do
    local lower = name:lower()
    if lower:match("^anthropic%-") or lower:match("^x%-stainless%-") or lower == "user-agent" then
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
    local httpc = http.new()
    httpc:set_timeout(60000)

    local t0 = ngx.now()
    local res, proxy_err = httpc:request_uri(upstream_url, {
        method  = ngx.var.request_method,
        body    = body_str,
        headers = upstream_headers,
        ssl_verify = true,
    })
    local latency_ms = (ngx.now() - t0) * 1000

    if not res then
        ngx.log(ngx.ERR, "upstream error (user=", user, " model=", model, "): ", proxy_err)
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
        -- Strip hop-by-hop headers and content-length (nginx recalculates from actual body)
        if lk ~= "transfer-encoding" and lk ~= "connection" and lk ~= "content-length" then
            ngx.header[k] = v
        end
    end

    local input_tokens, output_tokens, stop_reason, cache_creation, cache_read = 0, 0, nil, 0, 0
    if res.status == 200 then
        input_tokens, output_tokens, stop_reason, cache_creation, cache_read = provider.extract_tokens(response_body)
        track_rl_window(res)
    end
    if res.status == 429 then track_rl_429(res, user, model, provider_name) end

    ngx.print(response_body)
    ngx.flush(true)  -- send to client before tracking write
    pcall(tracking.record, user, provider_name, model, input_tokens, output_tokens,
          { latency_ms = latency_ms, status = res.status, stop_reason = stop_reason,
            cache_creation = cache_creation, cache_read = cache_read })
    return
end

-- Streaming path: proxy directly
local httpc = http.new()
httpc:set_timeout(120000)
local t0_stream = ngx.now()

local parsed_uri, parse_err2 = httpc:parse_uri(upstream_url, false)
if not parsed_uri then
    ngx.log(ngx.ERR, "streaming URI parse error: ", parse_err2)
    httpc:close()
    ngx.status = 500
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Internal proxy error"}')
    pcall(tracking.record, user, provider_name, model, 0, 0,
          { latency_ms = 0, status = 500 })
    return
end

local scheme, host, port, path, query = unpack(parsed_uri)
local ok, conn_err = httpc:connect({
    scheme          = scheme,
    host            = host,
    port            = port,
    ssl_server_name = host,
    ssl_verify      = true,
})
if not ok then
    ngx.log(ngx.ERR, "streaming connect error (user=", user, "): ", conn_err)
    httpc:close()
    ngx.status = 502
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"Failed to connect to upstream"}')
    pcall(tracking.record, user, provider_name, model, 0, 0,
          { latency_ms = (ngx.now() - t0_stream) * 1000, status = 502 })
    return
end

local req_path = (query and query ~= "") and (path .. "?" .. query) or path
local res, req_err = httpc:request({
    method  = ngx.var.request_method,
    path    = req_path,
    body    = body_str,
    headers = upstream_headers,
})

if not res then
    ngx.log(ngx.ERR, "streaming upstream error (user=", user, "): ", req_err)
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
    if lk ~= "transfer-encoding" and lk ~= "connection" and lk ~= "content-length" then
        ngx.header[k] = v
    end
end

-- Accumulate chunks for SSE token parsing while streaming to client
local chunks = {}
local had_read_err = false
local reader = res.body_reader
repeat
    local chunk, read_err = reader(8192)
    if read_err then
        ngx.log(ngx.ERR, "streaming read error (user=", user, "): ", read_err)
        had_read_err = true
        break
    end
    if chunk then
        ngx.print(chunk)
        ngx.flush(true)
        chunks[#chunks+1] = chunk
    end
until not chunk
if had_read_err then
    httpc:close()
else
    httpc:set_keepalive()
end

-- Parse SSE events for token tracking — delegate to provider-specific parser
local input_tokens, output_tokens, stop_reason = 0, 0, nil
local cache_creation, cache_read = 0, 0
if res.status == 200 and provider.extract_tokens_streaming then
    input_tokens, output_tokens, stop_reason, cache_creation, cache_read =
        provider.extract_tokens_streaming(table.concat(chunks))
end

if res.status == 200 then track_rl_window(res) end
if res.status == 429 then track_rl_429(res, user, model, provider_name) end

pcall(tracking.record, user, provider_name, model, input_tokens, output_tokens,
      { latency_ms = (ngx.now() - t0_stream) * 1000, status = res.status, stop_reason = stop_reason,
        cache_creation = cache_creation, cache_read = cache_read })
