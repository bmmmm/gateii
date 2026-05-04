-- bench_agg.lua: shared aggregation for bench-results.json
-- Used by admin_api.lua (/agents endpoint) and metrics.lua (Prometheus export).
local _M = {}
local cjson = require "cjson.safe"

local DEFAULT_PATH = "/etc/nginx/data/agents/bench-results.json"

-- load([path]) → aggregated bench data or nil on read/parse error.
-- Returns:
--   cells          {["task|model"] = {runs, passed, pass_rate, latency_p50}}
--   tasks          sorted list of distinct task names
--   models         sorted list of distinct model names
--   started_at     ISO timestamp string (from bench file)
--   started_epoch  Unix timestamp (from bench file, may be nil)
--   trials_per_cell number (from bench file)
--   model_created  {[model] = unix_epoch} (from bench file, may be nil)
function _M.load(path)
    path = path or DEFAULT_PATH
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a"); f:close()
    local ok, b = pcall(cjson.decode, content)
    if not ok or not b or type(b.results) ~= "table" then return nil end

    local cells = {}
    local tasks_set, models_set = {}, {}
    for _, r in ipairs(b.results) do
        local task  = r.task  or "?"
        local model = r.model or "?"
        local k = task .. "|" .. model
        cells[k] = cells[k] or { runs = 0, passed = 0, lats = {} }
        cells[k].runs = cells[k].runs + 1
        if r.compliant then cells[k].passed = cells[k].passed + 1 end
        table.insert(cells[k].lats, r.latency_s or 0)
        tasks_set[task]   = true
        models_set[model] = true
    end

    for _, c in pairs(cells) do
        table.sort(c.lats)
        local mid = math.ceil(#c.lats / 2)
        c.pass_rate   = c.runs > 0 and (c.passed / c.runs) or 0
        c.latency_p50 = c.lats[mid] or 0
        c.lats = nil
    end

    local tasks_list, models_list = {}, {}
    for t in pairs(tasks_set)  do table.insert(tasks_list,  t) end
    for m in pairs(models_set) do table.insert(models_list, m) end
    table.sort(tasks_list); table.sort(models_list)

    return {
        cells           = cells,
        tasks           = tasks_list,
        models          = models_list,
        started_at      = b.started_at,
        started_epoch   = b.started_epoch,
        trials_per_cell = b.trials_per_cell,
        model_created   = b.model_created,
    }
end

return _M
