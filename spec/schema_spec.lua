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

    it("accepts a hard-zero cap", function()
        -- is_nonneg_int: 0 is a deliberate block-everything cap, not an error.
        local ok = schema.validate_limits({ alice = { tokens_per_day = 0 } })
        assert.is_true(ok)
    end)

    it("drops invalid entries (tolerant) but keeps valid ones", function()
        -- Per-entry tolerant: one bad entry must NOT drop the whole file, else a
        -- single typo fails limits OPEN (every user's cap removed). Invalid entries
        -- are removed in place + WARN-logged; valid entries survive.
        local data = { alice = { tokens_per_day = -1 }, bob = { tokens_per_day = 100000 } }
        local ok = schema.validate_limits(data)
        assert.is_true(ok)
        assert.is_nil(data.alice)
        assert.is_not_nil(data.bob)
    end)
end)

describe("schema.validate_git_tracking", function()
    it("accepts an empty object", function()
        local ok = schema.validate_git_tracking({}); assert.is_true(ok)
    end)

    it("accepts a full config with repos and platform_authors", function()
        local ok = schema.validate_git_tracking({
            default_author = "bma",
            interval = 300,
            platform_authors = { forgejo = "bma", github = "bmmmm" },
            repos = {
                { path = "/repo/a", alias = "a", author = "bma", platform = "forgejo" },
                { path = "/repo/b" },
            },
        })
        assert.is_true(ok)
    end)

    it("rejects a non-object root", function()
        local ok, err = schema.validate_git_tracking("nope")
        assert.is_false(ok); assert.is_not_nil(err)
    end)

    it("rejects interval below the 30s floor", function()
        local ok, err = schema.validate_git_tracking({ interval = 5 })
        assert.is_false(ok); assert.is_not_nil(err)
    end)

    it("rejects a repo missing its required path", function()
        local ok, err = schema.validate_git_tracking({ repos = { { alias = "a" } } })
        assert.is_false(ok); assert.is_not_nil(err)
    end)

    it("rejects a platform tag that isn't [a-z0-9_-]+", function()
        local ok, err = schema.validate_git_tracking({
            repos = { { path = "/r", platform = "Git Hub!" } },
        })
        assert.is_false(ok); assert.is_not_nil(err)
    end)

    it("rejects a platform_authors key that isn't a valid tag", function()
        local ok, err = schema.validate_git_tracking({
            platform_authors = { ["Bad Key"] = "x" },
        })
        assert.is_false(ok); assert.is_not_nil(err)
    end)

    it("treats repos as optional (nil repos is valid)", function()
        local ok = schema.validate_git_tracking({ default_author = "bma" })
        assert.is_true(ok)
    end)
end)

describe("schema.validate_openrouter_free", function()
    it("accepts an empty object", function()
        local ok = schema.validate_openrouter_free({}); assert.is_true(ok)
    end)

    it("accepts a pool of :free ids plus a :free default", function()
        local ok = schema.validate_openrouter_free({
            pool = { "google/gemma-4-31b-it:free", "qwen/qwen3-coder:free" },
            default = "qwen/qwen3-coder:free",
        })
        assert.is_true(ok)
    end)

    it("accepts an empty-string default (no default)", function()
        local ok = schema.validate_openrouter_free({ pool = {}, default = "" })
        assert.is_true(ok)
    end)

    it("rejects a non-object root", function()
        local ok, err = schema.validate_openrouter_free("nope")
        assert.is_false(ok); assert.is_not_nil(err)
    end)

    it("rejects a pool entry that isn't a :free model", function()
        local ok, err = schema.validate_openrouter_free({ pool = { "anthropic/claude-opus-4" } })
        assert.is_false(ok); assert.is_not_nil(err)
    end)

    it("rejects a pool larger than 3 (OpenRouter models-array cap)", function()
        local ok, err = schema.validate_openrouter_free({
            pool = { "a:free", "b:free", "c:free", "d:free" },
        })
        assert.is_false(ok); assert.is_not_nil(err)
    end)

    it("rejects duplicate pool entries", function()
        local ok, err = schema.validate_openrouter_free({
            pool = { "a:free", "a:free" },
        })
        assert.is_false(ok); assert.is_not_nil(err)
    end)

    it("rejects a non-:free default", function()
        local ok, err = schema.validate_openrouter_free({ default = "gpt-4o" })
        assert.is_false(ok); assert.is_not_nil(err)
    end)
end)
