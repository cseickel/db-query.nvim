--[[
Marks each query a buffer ran with how its last run ended.

Every query keeps a diagnostic holding the outcome, such as `2,520 rows in
0.98s`, and the outcome's icon in the gutter beside its first line of code. The
query that ran last also gets the run-status elbow, turning under the query to
the outcome, until the buffer's text next changes.

A run replaces every mark its lines overlap, when it starts and again when it
finishes, so each query keeps only its last run. Deleting a query's text
deletes its marks.
]]

local runStatus = require("db-query.query.status")

local M = {}

local DIAGNOSTICS = vim.api.nvim_create_namespace("db_query_runs")
local SPANS = vim.api.nvim_create_namespace("db_query_run_spans")
local DRAWN = vim.api.nvim_create_namespace("db_query_run_marks")

---@type table<dbquery.Status, vim.diagnostic.Severity>
local SEVERITY = {
  ok = vim.diagnostic.severity.INFO,
  failed = vim.diagnostic.severity.ERROR,
  cancelled = vim.diagnostic.severity.HINT,
}

-- This module draws the signs and the outcome line itself, in the outcome's
-- colors, since a diagnostic sign takes its severity's.
vim.diagnostic.config({ underline = false, virtual_text = false, virtual_lines = false, signs = false }, DIAGNOSTICS)

---@class dbquery.FinishedRun
---@field status dbquery.Status
---@field diagnostic vim.Diagnostic
---@field width integer The elbow's width, measured when the run started.

--- Each buffer's runs, keyed by the extmark that follows their lines, and
--- false while the run is still going.
---@type table<integer, table<integer, dbquery.FinishedRun|false>>
local runs = {}

--- The extmark of the run each buffer finished last, which gets the elbow until
--- the buffer's text changes.
---@type table<integer, integer>
local latest = {}

--- Publishes `buf`'s diagnostics and draws its marks where their lines are now.
---@param buf integer
local function publish(buf)
  vim.api.nvim_buf_clear_namespace(buf, DRAWN, 0, -1)
  local diagnostics = {}
  for extmark, run in pairs(runs[buf] or {}) do
    local first, last = runStatus.spanRows(buf, SPANS, extmark)
    if run and first and last then
      run.diagnostic.lnum, run.diagnostic.end_lnum = first, last
      table.insert(diagnostics, run.diagnostic)
      ---@type dbquery.Mark
      local mark = {
        first = first,
        last = last,
        status = run.status,
        sign = runStatus.icon(run.status),
        text = run.diagnostic.message,
        width = run.width,
      }
      runStatus.drawSign(buf, DRAWN, mark)
      if extmark == latest[buf] then
        runStatus.drawElbow(buf, DRAWN, mark)
      end
    end
  end
  vim.diagnostic.set(DIAGNOSTICS, buf, diagnostics)
end

--- Forgets `buf`'s runs, finished or running, whose lines overlap rows `first`
--- to `last`, along with any whose text was deleted.
---@param buf integer
---@param first integer
---@param last integer
local function forget(buf, first, last)
  for extmark in pairs(runs[buf]) do
    local top, bottom = runStatus.spanRows(buf, SPANS, extmark)
    if not (top and bottom) or not (bottom < first or top > last) then
      vim.api.nvim_buf_del_extmark(buf, SPANS, extmark)
      runs[buf][extmark] = nil
    end
  end
end

--- Returns `buf`'s runs, starting to follow its edits on first use.
---@param buf integer
---@return table<integer, dbquery.FinishedRun|false>
local function runsOf(buf)
  if not runs[buf] then
    runs[buf] = {}
    -- nvim refuses editor changes inside these callbacks, so the elbow is
    -- removed on the next pass of the main loop.
    local function changed()
      if latest[buf] then
        latest[buf] = nil
        vim.schedule(function()
          if runs[buf] and vim.api.nvim_buf_is_loaded(buf) then
            publish(buf)
          end
        end)
      end
    end
    -- nvim detaches when the buffer is unloaded, which takes its marks with it.
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = changed,
      on_reload = changed,
      on_detach = function()
        runs[buf], latest[buf] = nil, nil
      end,
    })
    vim.api.nvim_create_autocmd("TextChanged", {
      group = vim.api.nvim_create_augroup("db-query.query.result." .. buf, { clear = true }),
      buffer = buf,
      callback = function()
        if runs[buf] then
          publish(buf)
        end
      end,
    })
  end
  return runs[buf]
end

--- Clears the marks of any earlier run over `span` and the buffer's elbow, and
--- marks the query with how `process` ended once it finishes.
---@param buf integer
---@param span [integer, integer] First and last line of the query (0-based).
---@param process dbquery.Process
function M.track(buf, span, process)
  local tracked = runsOf(buf)
  local extmark, width = runStatus.followSpan(buf, SPANS, span)
  local first, last = runStatus.spanRows(buf, SPANS, extmark)
  forget(buf, first or span[1], last or span[2])
  latest[buf] = nil
  publish(buf)
  tracked[extmark] = false

  process:onFinish(function()
    -- A later run over these lines has already forgotten this one.
    if not vim.api.nvim_buf_is_loaded(buf) or tracked[extmark] == nil then
      return
    end
    tracked[extmark] = nil
    local top, bottom = runStatus.spanRows(buf, SPANS, extmark)
    if not (top and bottom) then
      vim.api.nvim_buf_del_extmark(buf, SPANS, extmark)
      return
    end
    forget(buf, top, bottom)
    tracked[extmark] = {
      status = process.status,
      diagnostic = {
        bufnr = buf,
        lnum = top,
        end_lnum = bottom,
        col = 0,
        end_col = 0,
        severity = SEVERITY[process.status],
        message = runStatus.summary(process),
        source = "db-query",
      },
      width = width,
    }
    latest[buf] = extmark
    publish(buf)
  end)
end

return M
