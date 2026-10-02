--[[
Describes a column, table, or function as the catalog records it, in markdown.
]]

local describe = require("db-query.lsp.describe")
local names = require("db-query.lsp.names")
local target = require("db-query.lsp.target")

local M = {}

---@param lines string[]
---@param comment string|nil
local function appendComment(lines, comment)
  if comment and comment ~= "" then
    vim.list_extend(lines, { "", comment })
  end
end

--- Returns the parts that are not nil, joined by `separator`.
---@param separator string
---@param ... string|nil
---@return string
local function joined(separator, ...)
  local parts = {}
  for index = 1, select("#", ...) do
    local part = select(index, ...)
    if part ~= nil then
      parts[#parts + 1] = part
    end
  end
  return table.concat(parts, separator)
end

---@param column dbquery.Column
---@return string|nil
local function constraints(column)
  local filled = column.generated and ("generated " .. column.generated)
    or (column.default and ("default " .. column.default))
    or nil
  local line = joined(" ", (not column.nullable) and "not null" or nil, filled)
  return line ~= "" and line or nil
end

---@param column dbquery.Column
---@param relation dbquery.Relation
---@return string[]
local function describeColumn(column, relation)
  local qualifiedName = table.concat(names.qualifiedParts(relation), ".")
  local lines = { "```sql", qualifiedName .. "." .. joined(" ", column.name, column.type, constraints(column)), "```" }
  if column.labels then
    vim.list_extend(lines, { "", "values: " .. table.concat(column.labels, ", ") })
  end
  appendComment(lines, column.comment)
  return lines
end

---@param relation dbquery.Relation
---@return string[]
local function describeRelation(relation)
  local lines = {}
  if relation.comment and relation.comment ~= "" then
    lines = { relation.comment, "" }
  end
  vim.list_extend(lines, { "```sql", relation.kind .. " " .. table.concat(names.qualifiedParts(relation), ".") })
  local columnLines = describe.aligned(vim.tbl_map(function(column)
    local comment = column.comment and column.comment ~= "" and ("-- " .. column.comment:gsub("\r?\n", "\n-- ")) or ""
    return { column.name, column.type or "", constraints(column) or "", comment }
  end, relation.columns))
  for _, line in ipairs(columnLines) do
    lines[#lines + 1] = "  " .. line
  end
  lines[#lines + 1] = "```"
  return lines
end

---@param dialect dbquery.Dialect
---@param functions dbquery.Function[]
---@return string[]
local function describeFunctions(dialect, functions)
  local lines = {}
  for _, fn in ipairs(functions) do
    local argumentLabels = vim.tbl_map(describe.argument, describe.passed(fn))
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    local signature = fn.kind .. " " .. joined(".", fn.schema, fn.name) .. "(" .. table.concat(argumentLabels, ", ") .. ")"
    local resultLines = describe.result(dialect, fn) or {}
    lines[#lines + 1] = "```sql"
    lines[#lines + 1] = signature .. (resultLines[1] and (" → " .. resultLines[1]) or "")
    vim.list_extend(lines, resultLines, 2)
    lines[#lines + 1] = "```"
    appendComment(lines, fn.comment)
  end
  return lines
end

--- Returns the lines of markdown that describe `named`.
---@param dialect dbquery.Dialect
---@param named dbquery.Target
---@return string[]
function M.markdown(dialect, named)
  if named.kind == "column" then
    return describeColumn(named.column, named.relation)
  elseif named.kind == "relation" then
    return describeRelation(named.relation)
  end
  return describeFunctions(dialect, named.functions)
end

--- Returns, as markdown, the column, table, or function overloads the catalog
--- holds under the word in `context`, or nil when the catalog holds none.
---@param opened dbquery.Opened
---@param context dbquery.CursorContext
---@return lsp.Hover|nil
function M.hover(opened, context)
  local named = target.at(opened, context)
  if not named then
    return nil
  end
  local lines = M.markdown(opened.document.dialect, named)
  return { contents = { kind = "markdown", value = table.concat(lines, "\n") } }
end

return M
