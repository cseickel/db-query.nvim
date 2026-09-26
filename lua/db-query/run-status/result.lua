--[[
Marks each query a buffer ran with how its last run ended.

Every query keeps a diagnostic holding the outcome, such as `2,520 rows in
0.98s`, and the outcome's icon in the gutter beside its first line of code. The
query that ran last also gets the run-status elbow, turning under the query to
the outcome, until the buffer next enters insert mode.

A run replaces every mark its lines overlap, when it starts and again when it
finishes, so each query keeps only its last run. Each run has an extmark
following its lines through edits, and everything is drawn again from those
marks whenever the buffer changes outside insert mode. Deleting a query's text
deletes its marks.
]]

local runStatus = require("db-query.run-status")

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

--- The mark of the run each buffer finished last, which gets the elbow until
--- the buffer enters insert mode.
---@type table<integer, integer>
local latest = {}

--- Returns the first and last row of extmark `mark`, or nil once it is gone or
--- its text was deleted.
---@param buf integer
---@param mark integer
---@return integer|nil first
---@return integer|nil last
local function rows(buf, mark)
  local placed = vim.api.nvim_buf_get_extmark_by_id(buf, SPANS, mark, { details = true })
  local first, details = placed[1], placed[3]
  if not (first and details) or details.invalid then
    return nil, nil
  end
  return first, math.max(first, details.end_row or first)
end

--- Publishes `buf`'s diagnostics and draws its marks where their lines are now.
---@param buf integer
local function publish(buf)
  vim.api.nvim_buf_clear_namespace(buf, DRAWN, 0, -1)
  local list = {}
  for mark, run in pairs(runs[buf] or {}) do
    local first, last = rows(buf, mark)
    if run and first and last then
      run.diagnostic.lnum, run.diagnostic.end_lnum = first, last
      table.insert(list, run.diagnostic)
      ---@type dbquery.Mark
      local drawn = {
        first = first,
        last = last,
        status = run.status,
        sign = runStatus.icon(run.status),
        text = run.diagnostic.message,
        width = run.width,
      }
      runStatus.drawSign(buf, DRAWN, drawn)
      if mark == latest[buf] then
        runStatus.drawElbow(buf, DRAWN, drawn)
      end
    end
  end
  vim.diagnostic.set(DIAGNOSTICS, buf, list)
end

--- Forgets `buf`'s runs, finished or running, whose lines overlap rows `first`
--- to `last`, along with any whose text was deleted.
---@param buf integer
---@param first integer
---@param last integer
local function forget(buf, first, last)
  for mark in pairs(runs[buf]) do
    local top, bottom = rows(buf, mark)
    if not (top and bottom) or not (bottom < first or top > last) then
      vim.api.nvim_buf_del_extmark(buf, SPANS, mark)
      runs[buf][mark] = nil
    end
  end
end

--- Returns `buf`'s runs, starting to follow its edits on first use.
---@param buf integer
---@return table<integer, dbquery.FinishedRun|false>
local function runsOf(buf)
  if not runs[buf] then
    runs[buf] = {}
    vim.api.nvim_create_autocmd("TextChanged", {
      buffer = buf,
      callback = function()
        publish(buf)
      end,
    })
    vim.api.nvim_create_autocmd("InsertEnter", {
      buffer = buf,
      callback = function()
        if latest[buf] then
          latest[buf] = nil
          publish(buf)
        end
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        runs[buf], latest[buf] = nil, nil
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
  local bottom = vim.api.nvim_buf_line_count(buf) - 1
  local first, last = math.min(span[1], bottom), math.min(span[2], bottom)
  forget(buf, first, last)
  latest[buf] = nil
  publish(buf)

  local lastLine = vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1]
  local mark = vim.api.nvim_buf_set_extmark(buf, SPANS, first, 0, {
    end_row = last,
    end_col = #lastLine,
    invalidate = true,
  })
  tracked[mark] = false
  local width = runStatus.widthAt(buf, last)

  process:onFinish(function()
    -- A later run over these lines has already forgotten this one.
    if not vim.api.nvim_buf_is_loaded(buf) or tracked[mark] == nil then
      return
    end
    tracked[mark] = nil
    local top, bottomRow = rows(buf, mark)
    if not (top and bottomRow) then
      vim.api.nvim_buf_del_extmark(buf, SPANS, mark)
      return
    end
    forget(buf, top, bottomRow)
    tracked[mark] = {
      status = process.status,
      diagnostic = {
        lnum = top,
        end_lnum = bottomRow,
        col = 0,
        severity = SEVERITY[process.status],
        message = runStatus.summary(process),
        source = "db-query",
      },
      width = width,
    }
    latest[buf] = mark
    publish(buf)
  end)
end

return M
