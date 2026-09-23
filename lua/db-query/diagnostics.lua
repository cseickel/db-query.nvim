--[[
Marks each query a buffer ran with how its last run ended.

Every query keeps a diagnostic holding the outcome, such as `2520 rows in
0.98s`, and the outcome's icon in the gutter beside its first line of code. The
query that ran last also gets an elbow: a bar down the gutter beside the rest of
its lines, turning under the query to the outcome.

    icon │ select month, sum(amount)
    │    │ from trades
    ╰───────────┤ 2520 rows in 0.98s ▕

A run replaces every mark its lines overlap, when it starts and again when it
finishes, so each query keeps only its last run. Each run has an extmark
following its lines through edits, and everything is drawn again from those
marks whenever the buffer changes outside insert mode. Deleting a query's text
deletes its marks.
]]

local Indicator = require("db-query.indicator")
local lex = require("db-query.sql.lex")
local outcome = require("db-query.outcome")

local M = {}

local DIAGNOSTICS = vim.api.nvim_create_namespace("db_query_runs")
local SPANS = vim.api.nvim_create_namespace("db_query_run_spans")
local DRAWN = vim.api.nvim_create_namespace("db_query_run_marks")
local INDENT = 3

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

--- Each buffer's runs, keyed by the extmark that follows their lines, and
--- false while the run is still going.
---@type table<integer, table<integer, dbquery.FinishedRun|false>>
local runs = {}

--- The mark of the run each buffer finished last, which gets the elbow.
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

--- Draws the bar beside rows after `first` through `last`, and the elbow under
--- `last` turning to the outcome.
---@param buf integer
---@param first integer
---@param last integer
---@param run dbquery.FinishedRun
local function drawElbow(buf, first, last, run)
  local color = outcome.highlight(run.status)
  if last > first then
    vim.api.nvim_buf_set_extmark(buf, DRAWN, first + 1, 0, {
      end_row = last,
      sign_text = "│",
      sign_hl_group = color,
    })
  end
  -- The result starts INDENT cells into the text, where no line of sql does.
  local elbow = "╰" .. string.rep("─", Indicator.textColumn(buf) + INDENT - 1)
  local band = outcome.band(run.status)
  vim.api.nvim_buf_set_extmark(buf, DRAWN, last, 0, {
    virt_lines = {
      {
        { elbow, color },
        { "▏", { outcome.text(run.status), outcome.ITALIC } },
        { " " .. run.diagnostic.message .. " ", { outcome.text(run.status), outcome.ITALIC } },
        -- Drawn along the cell's right edge, where the band ends.
        { "▕", band },
      },
    },
    virt_lines_leftcol = true,
  })
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
      vim.api.nvim_buf_set_extmark(buf, DRAWN, first, 0, {
        -- A sign holds at most two cells.
        sign_text = vim.fn.strcharpart(outcome.icon(run.status), 0, 2),
        sign_hl_group = outcome.highlight(run.status),
      })
      if mark == latest[buf] then
        drawElbow(buf, first, last, run)
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

--- Returns how many lines into `lines` the first token that is not a comment
--- starts, or 0 when there is none.
---@param dialect dbquery.Dialect
---@param lines string[]
---@return integer
local function codeOffset(dialect, lines)
  local text = table.concat(lines, "\n")
  for _, token in ipairs(lex.tokens(dialect, text)) do
    if token.kind ~= "comment" then
      return select(2, text:sub(1, token.first - 1):gsub("\n", ""))
    end
  end
  return 0
end

--- Clears the marks of any earlier run over `ctx.span` and the buffer's elbow,
--- and marks the query with how `process` ended once it finishes.
---@param ctx dbquery.Context
---@param process dbquery.Process
function M.track(ctx, process)
  local buf = ctx.buf
  local tracked = runsOf(buf)
  local bottom = vim.api.nvim_buf_line_count(buf) - 1
  local first, last = math.min(ctx.span[1], bottom), math.min(ctx.span[2], bottom)
  forget(buf, first, last)
  latest[buf] = nil
  publish(buf)

  local lines = vim.api.nvim_buf_get_lines(buf, first, last + 1, false)
  local mark = vim.api.nvim_buf_set_extmark(buf, SPANS, first + codeOffset(ctx.dialect, lines), 0, {
    end_row = last,
    end_col = #lines[#lines],
    invalidate = true,
  })
  tracked[mark] = false

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
        message = outcome.summary(process),
        source = "db-query",
      },
    }
    latest[buf] = mark
    publish(buf)
  end)
end

return M
