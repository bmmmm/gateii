-- handler.lua: proxy + token tracking
local cjson    = require "cjson.safe"
local http     = require "resty.http"
local providers = require "providers.init"
local tracking  = require "tracking"

-- Read body — with temp-file fallback for concurrent load (body buffered to disk)
local body_str = ngx.req.get_body_data()
if not body_str then
    local body_file = ngx.req.get_body_file()
    if body_file then
        local f = io.open(body_file, "rb")
        if f then
            local ok, result = pcall(f.read, f, "*a")
            f:close()
            if ok then body_str = result end
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
        end
    end
end
local upstream_url = provider.upstream_url .. ngx.var.uri

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

    local input_tokens, output_tokens, stop_reason = 0, 0, nil
    if res.status == 200 then
        input_tokens, output_tokens, stop_reason = provider.extract_tokens(response_body)
    end

    ngx.print(response_body)
    ngx.flush(true)  -- send to client before tracking write
    pcall(tracking.record, user, provider_name, model, input_tokens, output_tokens,
          { latency_ms = latency_ms, status = res.status, stop_reason = stop_reason })
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

-- Parse SSE events for token tracking (Anthropic sends usage in message_start + message_delta)
-- Handle both \r\n (HTTP spec) and \n (common in practice) line endings
local input_tokens, output_tokens, stop_reason = 0, 0, nil
if res.status == 200 then
    local body = table.concat(chunks)
    local data = body:match("event: message_start\r?\ndata: ([^\r\n]+)")
    if data then
        local obj, err = cjson.decode(data)
        if obj and obj.message and obj.message.usage then
            input_tokens = obj.message.usage.input_tokens or 0
        elseif not obj then
            ngx.log(ngx.WARN, "failed to decode message_start SSE: ", err)
        end
    end
    data = body:match("event: message_delta\r?\ndata: ([^\r\n]+)")
    if data then
        local obj, err = cjson.decode(data)
        if not obj then
            ngx.log(ngx.WARN, "failed to decode message_delta SSE: ", err)
        elseif obj then
            if obj.usage then output_tokens = obj.usage.output_tokens or 0 end
            if obj.delta then stop_reason = obj.delta.stop_reason end
        end
    end
end

pcall(tracking.record, user, provider_name, model, input_tokens, output_tokens,
      { latency_ms = (ngx.now() - t0_stream) * 1000, status = res.status, stop_reason = stop_reason })
