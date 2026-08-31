--[[
Extracting sql from a buffer.

Supports whole buffer, command range, visual selection, or statement at cursor.
Returns both the sql text and the line span for the indicator.
]]

local sql = require("db-query.sql")

local M = {}

---@class dbquery.Selection
---@field visual boolean|nil Use visual selection (live or just ended).
---@field range [integer, integer]|nil Command range as first and last line.
---@field statement boolean|nil Statement containing the cursor.

--- Returns the visual selection text and line span.
---@return string[] lines
---@return [integer, integer] span
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

--- Returns the sql text and line span for `opts`. Defaults to whole buffer.
---@param opts dbquery.Selection
---@return string sql
---@return [integer, integer] span
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
