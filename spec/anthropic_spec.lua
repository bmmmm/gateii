-- spec/anthropic_spec.lua
-- Tests for the Anthropic provider SSE parser.
-- Run with: busted spec/anthropic_spec.lua
-- Requires: luarocks install busted cjson

-- Stub ngx and os.getenv so the module loads outside OpenResty
_G.ngx = { null = nil }
local real_getenv = os.getenv
os.getenv = function(k)
    if k == "ANTHROPIC_API_KEY" then return "test-key" end
    return real_getenv(k)
end

-- Make require find modules in the right place
package.path = package.path .. ";config/openresty/lua/?.lua;config/openresty/lua/?/init.lua"

local cjson = require "cjson.safe"

local function read_fixture(name)
    local f = io.open("spec/fixtures/sse/" .. name, "r")
    assert(f, "fixture not found: " .. name)
    local content = f:read("*a"); f:close()
    return content
end

describe("anthropic provider", function()
    local anthropic

    before_each(function()
        -- Force fresh require (clear cached module)
        package.loaded["providers/anthropic"] = nil
        -- Stub cjson via package.loaded so the module picks it up
        package.loaded["cjson.safe"] = require("cjson.safe")
        anthropic = require("providers/anthropic")
    end)

    describe("parse_sse_events", function()
        it("parses normal message stream", function()
            local body = read_fixture("normal_message.txt")
            local events = anthropic.parse_sse_events(body)
            -- Should have: message_start, content_block_start, ping, content_block_delta, content_block_stop, message_delta, message_stop
            assert.is_true(#events >= 4)
            assert.equals("message_start", events[1].event)
            assert.equals("message_delta", events[#events - 1].event)
            assert.equals("message_stop", events[#events].event)
        end)

        it("ignores SSE comment lines", function()
            local body = read_fixture("keep_alive_comments.txt")
            local events = anthropic.parse_sse_events(body)
            for _, ev in ipairs(events) do
                -- No event should have data starting with ":"
                assert.is_not_nil(ev.event)
            end
            -- Only real events, no comment pseudo-events
            assert.equals("message_start", events[1].event)
        end)

        it("handles empty body gracefully", function()
            local events = anthropic.parse_sse_events("")
            assert.equals(0, #events)
        end)

        it("handles body with only comments and keep-alives", function()
            local events = anthropic.parse_sse_events(": keep-alive\n\n: ping\n\n")
            assert.equals(0, #events)
        end)
    end)

    describe("extract_tokens_streaming", function()
        it("extracts tokens from normal message", function()
            local body = read_fixture("normal_message.txt")
            local inp, out, stop, cc, cr = anthropic.extract_tokens_streaming(body)
            assert.equals(25, inp)
            assert.equals(1, out)
            assert.equals("end_turn", stop)
            assert.equals(0, cc)
            assert.equals(0, cr)
        end)

        it("extracts cache tokens", function()
            local body = read_fixture("with_cache.txt")
            local inp, out, stop, cc, cr = anthropic.extract_tokens_streaming(body)
            assert.equals(10, inp)
            assert.equals(42, out)
            assert.equals("end_turn", stop)
            assert.equals(500, cc)
            assert.equals(1000, cr)
        end)

        it("handles keep-alive comments correctly", function()
            local body = read_fixture("keep_alive_comments.txt")
            local inp, out, stop, cc, cr = anthropic.extract_tokens_streaming(body)
            assert.equals(5, inp)
            assert.equals(7, out)
            assert.equals("end_turn", stop)
        end)

        it("extracts max_tokens stop reason", function()
            local body = read_fixture("max_tokens_stop.txt")
            local inp, out, stop, _, _ = anthropic.extract_tokens_streaming(body)
            assert.equals(100, inp)
            assert.equals(200, out)
            assert.equals("max_tokens", stop)
        end)

        it("returns zeros for empty body", function()
            local inp, out, stop, cc, cr = anthropic.extract_tokens_streaming("")
            assert.equals(0, inp)
            assert.equals(0, out)
            assert.is_nil(stop)
            assert.equals(0, cc)
            assert.equals(0, cr)
        end)
    end)
end)
