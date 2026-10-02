--[[
Writes catalog objects out as the text hover, completion, and signature help
show.
]]

local names = require("db-query.lsp.names")

local M = {}

--- Returns the rows as lines, with each cell but the last padded so the cells
--- of every row start in the same column. A last cell holding several lines
--- gives one line each, and its later lines start in the column its first
--- line starts in. Trailing spaces are removed.
---@param rows string[][]
---@return string[]
function M.aligned(rows)
  local widths = {}
  for _, row in ipairs(rows) do
    for index = 1, #row - 1 do
      widths[index] = math.max(widths[index] or 0, vim.fn.strdisplaywidth(row[index]))
    end
  end
  local lines = {}
  for _, row in ipairs(rows) do
    local lead = ""
    for index = 1, #row - 1 do
      lead = lead .. row[index] .. string.rep(" ", widths[index] - vim.fn.strdisplaywidth(row[index]) + 1)
    end
    local indent = string.rep(" ", vim.fn.strdisplaywidth(lead))
    for index, cellLine in ipairs(vim.split(row[#row], "\n", { plain = true })) do
      lines[#lines + 1] = ((index == 1 and lead or indent) .. cellLine):gsub("%s+$", "")
    end
  end
  return lines
end

--- Returns the arguments a call of `fn` passes. A call never passes a table
--- argument, and passes an out argument only to a procedure.
---@param fn dbquery.Function
---@return dbquery.Argument[]
function M.passed(fn)
  return vim.iter(fn.args):filter(function(arg)
    return arg.mode ~= "table" and (arg.mode ~= "out" or fn.kind == "procedure")
  end):totable()
end

--- Returns the named table, out, and inout arguments of `fn`, which are the
--- columns it returns.
---@param fn dbquery.Function
---@return dbquery.Argument[]
function M.returned(fn)
  return vim.iter(fn.args):filter(function(arg)
    return (arg.mode == "table" or arg.mode == "out" or arg.mode == "inout") and arg.name ~= nil
  end):totable()
end

--- Returns an argument as a signature shows it, such as `out total numeric`.
--- An argument a call may leave out is in brackets, and one with no name or
--- type reads `value`.
---@param arg dbquery.Argument
---@return string
function M.argument(arg)
  local parts = {}
  if arg.mode ~= "in" then
    parts[#parts + 1] = arg.mode
  end
  parts[#parts + 1] = arg.name
  parts[#parts + 1] = arg.type
  local label = table.concat(parts, " ")
  if label == "" then
    label = "value"
  end
  return arg.default and ("[" .. label .. "]") or label
end

--- Returns what `fn` returns, one line when it names a type, and one line per
--- column when it returns table or out arguments, as below.
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
  local returned = M.returned(fn)
  if #returned == 0 or fn.kind == "procedure" then
    return { fn.result }
  end
  local head = fn.result:match("^TABLE%s*%(") and "TABLE" or fn.result
  local lines = { head .. " (" }
  local columnLines = M.aligned(vim.tbl_map(function(arg)
    return { names.quote(dialect, arg.name), arg.type or "" }
  end, returned))
  for index, line in ipairs(columnLines) do
    lines[#lines + 1] = "  " .. line .. (index < #columnLines and "," or "")
  end
  lines[#lines + 1] = ")"
  return lines
end

return M
