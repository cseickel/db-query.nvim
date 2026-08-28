--[[
Which lines of a buffer a query is made of.

A query is the whole buffer, a command's range, the visual selection, or the
statement the cursor is in. All four answer with the same two things: the sql,
and the lines it came from, which is what the running indicator is drawn beside.
]]

local sql = require("db-query.sql")

local M = {}

--- Which sql to run. Nothing named means the whole buffer.
---@class dbquery.Selection
---@field visual boolean|nil The visual selection, live or the one just ended.
---@field range [integer, integer]|nil First and last line, as a command's range gives them.
---@field statement boolean|nil The statement the cursor is in, of however many the buffer holds.

--- The visual selection, and the lines it starts and ends on. Empty when
--- nothing is selected.
---
--- A `<cmd>` mapping leaves visual mode on and `'<` and `'>` still holding the
--- previous selection, so the live selection is read while it is there and the
--- marks only after it has ended, which is how a `-range` command arrives.
---@return string[] lines
---@return [integer, integer] span First and last line, as nvim counts them.
local function visual()
  local mode = vim.fn.mode()
  local from, to = vim.fn.getpos("v"), vim.fn.getpos(".")
  if not (mode == "v" or mode == "V" or mode == "\22") then
    mode = vim.fn.visualmode()
    if mode == "" then
      return {}, { 0, 0 }
    end
    from, to = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  end

  local lines = vim.fn.getregion(from, to, { type = mode })
  return lines, { math.min(from[2], to[2]) - 1, math.max(from[2], to[2]) - 1 }
end

--- The sql `opts` names, and the lines it was taken from.
---@param opts dbquery.Selection
---@return string sql
---@return [integer, integer] span First and last line, as nvim counts them.
function M.text(opts)
  local lines, span
  if opts.range then
    lines = vim.api.nvim_buf_get_lines(0, opts.range[1] - 1, opts.range[2], false)
    span = { opts.range[1] - 1, opts.range[2] - 1 }
  elseif opts.visual then
    lines, span = visual()
  elseif opts.statement then
    local buffer = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local found = sql.statementAt(buffer, vim.api.nvim_win_get_cursor(0)[1] - 1)
    span = found or { 0, 0 }
    lines = found and vim.list_slice(buffer, found[1] + 1, found[2] + 1) or {}
  else
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    span = { 0, #lines - 1 }
  end
  return vim.trim(table.concat(lines, "\n")), span
end

return M
