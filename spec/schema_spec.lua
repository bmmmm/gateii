-- spec/schema_spec.lua
-- Tests for config/openresty/lua/schema.lua validators.
-- Run with: busted spec/schema_spec.lua

package.path = package.path .. ";config/openresty/lua/?.lua"

local schema = require "schema"

describe("schema.validate_keys", function()
    it("accepts an empty object", function()
        local ok, err = schema.validate_keys({})
        assert.is_true(ok); assert.is_nil(err)
    end)

    it("accepts a well-formed structured entry", function()
        local ok, err = schema.validate_keys({
            ["sk-proxy-abcdef01abcdef01abcdef01abcdef01"] = {
                user          = "alice",
                provider      = "anthropic",
                upstream_key  = "sk-ant-api03-xxx",
            },
        })
        assert.is_true(ok); assert.is_nil(err)
    end)

    it("rejects non-object root", function()
        local ok, err = schema.validate_keys("nope")
        assert.is_false(ok); assert.matches("root must be an object", err)
    end)

    it("rejects keys shorter than 8 chars", function()
        local ok, err = schema.validate_keys({ ["short"] = { user="a", provider="b", upstream_key="c" } })
        assert.is_false(ok); assert.matches("too short", err)
    end)

    it("rejects the old flat {key: user-string} format", function()
        local ok, err = schema.validate_keys({ ["sk-proxy-long-enough-key"] = "alice" })
        assert.is_false(ok)
        assert.matches("value must be an object", err)
        assert.matches("flat {key:user} format is no longer supported", err)
    end)

    it("rejects entry with missing user", function()
        local ok, err = schema.validate_keys({
            ["sk-proxy-long-enough-key"] = { provider="anthropic", upstream_key="sk-ant-x" },
        })
        assert.is_false(ok); assert.matches("%.user: must be a non%-empty string", err)
    end)

    it("rejects entry with missing provider", function()
        local ok, err = schema.validate_keys({
            ["sk-proxy-long-enough-key"] = { user="alice", upstream_key="sk-ant-x" },
        })
        assert.is_false(ok); assert.matches("%.provider: must be a non%-empty string", err)
    end)

    it("rejects entry with missing upstream_key", function()
        local ok, err = schema.validate_keys({
            ["sk-proxy-long-enough-key"] = { user="alice", provider="anthropic" },
        })
        assert.is_false(ok); assert.matches("%.upstream_key: must be a non%-empty string", err)
    end)

    it("rejects entry with empty string user", function()
        local ok, err = schema.validate_keys({
            ["sk-proxy-long-enough-key"] = { user="", provider="anthropic", upstream_key="sk-ant-x" },
        })
        assert.is_false(ok); assert.matches("%.user", err)
    end)

    it("rejects entry with non-string provider type", function()
        local ok, err = schema.validate_keys({
            ["sk-proxy-long-enough-key"] = { user="alice", provider=42, upstream_key="sk-ant-x" },
        })
        assert.is_false(ok); assert.matches("%.provider", err)
    end)
end)

describe("schema.validate_providers", function()
    it("accepts minimal valid config", function()
        local ok = schema.validate_providers({
            active_provider = "anthropic",
            providers = { { id = "anthropic" } },
        })
        assert.is_true(ok)
    end)

    it("rejects active_provider referencing unknown id", function()
        local ok, err = schema.validate_providers({
            active_provider = "ghost",
            providers = { { id = "anthropic" } },
        })
        assert.is_false(ok); assert.matches("does not match any provider id", err)
    end)

    it("rejects duplicate provider ids", function()
        local ok, err = schema.validate_providers({
            active_provider = "anthropic",
            providers = { { id = "anthropic" }, { id = "anthropic" } },
        })
        assert.is_false(ok); assert.matches("duplicate id", err)
    end)
end)

describe("schema.validate_limits", function()
    it("accepts empty object", function()
        local ok = schema.validate_limits({}); assert.is_true(ok)
    end)

    it("accepts user with tokens_per_day", function()
        local ok = schema.validate_limits({ alice = { tokens_per_day = 100000 } })
        assert.is_true(ok)
    end)

    it("rejects negative limits", function()
        local ok, err = schema.validate_limits({ alice = { tokens_per_day = -1 } })
        assert.is_false(ok); assert.matches("must be a positive integer", err)
    end)
end)
