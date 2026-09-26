--[[
Extracting sql from a buffer.

`capture` reads the lines the query comes from: the whole buffer, a command
range, the visual selection, or the buffer and cursor row for the statement at
the cursor. It runs first, while the selection and cursor are still where the
user left them. `sql` turns a capture into the sql to run, and finds the
statement at the cursor once the connection says which dialect to read it by.
]]

local sql = require("db-query.sql")

local M = {}

---@class dbquery.Selection
---@field visual boolean|nil Use visual selection (live or just ended).
---@field range [integer, integer]|nil Command range as first and last line.
---@field statement boolean|nil Statement containing the cursor.

--- Lines that are the query as they stand.
---@class dbquery.LinesCapture
---@field kind "lines"
---@field lines string[]
---@field span [integer, integer] First and last line they came from.
---@field above string[] The buffer's lines before `span`.

--- A whole buffer and the cursor row, holding the statement to run.
---@class dbquery.StatementCapture
---@field kind "statement"
---@field lines string[]
---@field row integer 0-based cursor row.

---@alias dbquery.Capture dbquery.LinesCapture|dbquery.StatementCapture

---@param lines string[]
---@param span [integer, integer]
---@return dbquery.LinesCapture
local function linesCapture(lines, span)
  return { kind = "lines", lines = lines, span = span, above = vim.api.nvim_buf_get_lines(0, 0, span[1], false) }
end

--- Captures the lines `opts` asks for from the current buffer. Defaults to the
--- whole buffer.
---@param opts dbquery.Selection
---@return dbquery.Capture
function M.capture(opts)
  if opts.statement then
    return {
      kind = "statement",
      lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
      row = vim.api.nvim_win_get_cursor(0)[1] - 1,
    }
  end
  if opts.range then
    local span = { opts.range[1] - 1, opts.range[2] - 1 }
    return linesCapture(vim.api.nvim_buf_get_lines(0, span[1], span[2] + 1, false), span)
  end
  if opts.visual then
    -- A selection that already ended is read from its marks.
    local mode = vim.fn.mode()
    local from, to = vim.fn.getpos("v"), vim.fn.getpos(".")
    if not (mode == "v" or mode == "V" or mode == "\22") then
      mode = vim.fn.visualmode()
      if mode == "" then
        return linesCapture({}, { 0, 0 })
      end
      from, to = vim.fn.getpos("'<"), vim.fn.getpos("'>")
    end
    local span = { math.min(from[2], to[2]) - 1, math.max(from[2], to[2]) - 1 }
    return linesCapture(vim.fn.getregion(from, to, { type = mode }), span)
  end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  return linesCapture(lines, { 0, #lines - 1 })
end

--- Returns true when every captured line is blank, so no dialect can find a
--- query in them.
---@param capture dbquery.Capture
---@return boolean
function M.blank(capture)
  return vim.trim(table.concat(capture.lines, "\n")) == ""
end

--- Returns the sql text and line span of `capture`, reading the statement at
--- the cursor by the rules of `dialect`. When the lines above the sql leave the
--- client on a delimiter other than `;`, the command setting it comes first.
---@param capture dbquery.Capture
---@param dialect dbquery.Dialect
---@return string sql
---@return [integer, integer] span
function M.sql(capture, dialect)
  local lines, span, above
  if capture.kind == "lines" then
    lines, span, above = capture.lines, capture.span, capture.above
  else
    local statementSpan = sql.statementAt(dialect, capture.lines, capture.row)
    if not statementSpan then
      return "", { 0, 0 }
    end
    lines, span = vim.list_slice(capture.lines, statementSpan[1] + 1, statementSpan[2] + 1), statementSpan
    above = vim.list_slice(capture.lines, 1, statementSpan[1])
  end

  local sqlText = vim.trim(table.concat(lines, "\n"))
  local command = sqlText ~= "" and sql.delimiterCommand(dialect, above)
  return command and (command .. "\n" .. sqlText) or sqlText, span
end

return M
