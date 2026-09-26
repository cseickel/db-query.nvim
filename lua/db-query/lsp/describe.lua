--[[
Catalog objects written out as the text hover, completion, and signature help
show.
]]

local names = require("db-query.lsp.names")

local M = {}

--- Returns one line per row, with each cell but the last padded so the cells
--- of every row start in the same column. Trailing spaces are removed.
---@param rows string[][]
---@return string[]
function M.aligned(rows)
  local widths = {}
  for _, row in ipairs(rows) do
    for index, cell in ipairs(row) do
      widths[index] = math.max(widths[index] or 0, vim.fn.strdisplaywidth(cell))
    end
  end
  return vim.tbl_map(function(row)
    local cells = {}
    for index, cell in ipairs(row) do
      cells[index] = index < #row and (cell .. string.rep(" ", widths[index] - vim.fn.strdisplaywidth(cell))) or cell
    end
    return (table.concat(cells, " "):gsub("%s+$", ""))
  end, rows)
end

--- Returns the arguments a call of `fn` passes: never a table argument, and an
--- out argument only to a procedure.
---@param fn dbquery.Function
---@return dbquery.Argument[]
function M.passed(fn)
  return vim.iter(fn.args):filter(function(arg)
    return arg.mode ~= "table" and (arg.mode ~= "out" or fn.kind == "procedure")
  end):totable()
end

--- Returns what `fn` returns, one line when it names a type, and one line per
--- column when it returns table or out arguments:
---
---     TABLE (
---       ticker    text,
---       "earnDay" date
---     )
---
--- Returns nil when the catalog records no result.
---@param dialect dbquery.Dialect
---@param fn dbquery.Function
---@return string[]|nil
function M.result(dialect, fn)
  if not fn.result then
    return nil
  end
  local rows = {}
  for _, arg in ipairs(fn.args) do
    local returned = arg.mode == "table" or arg.mode == "out" or arg.mode == "inout"
    if returned and arg.name then
      rows[#rows + 1] = { names.quote(dialect, arg.name), arg.type or "" }
    end
  end
  if #rows == 0 or fn.kind == "procedure" then
    return { fn.result }
  end
  local head = fn.result:match("^TABLE%s*%(") and "TABLE" or fn.result
  local lines = { head .. " (" }
  local columns = M.aligned(rows)
  for index, line in ipairs(columns) do
    lines[#lines + 1] = "  " .. line .. (index < #columns and "," or "")
  end
  lines[#lines + 1] = ")"
  return lines
end

return M
