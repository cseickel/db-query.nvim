--[[
Hover for the name under the cursor: a column, a table, or a function, as the
catalog describes it.
]]

local describe = require("db-query.lsp.describe")
local target = require("db-query.lsp.target")

local M = {}

---@param lines string[]
---@param text string|nil
local function comment(lines, text)
  if text and text ~= "" then
    vim.list_extend(lines, { "", text })
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

---@param relation dbquery.Relation
---@return string
local function qualifiedName(relation)
  return joined(".", relation.database, relation.schema, relation.name)
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
---@return string
local function columnLine(column)
  return joined(" ", column.name, column.type, constraints(column))
end

--- Returns one line per column, with the names, types, and constraints each
--- starting in the same column.
---@param columns dbquery.Column[]
---@return string[]
local function columnTable(columns)
  return describe.aligned(vim.tbl_map(function(column)
    return { column.name, column.type or "", constraints(column) or "" }
  end, columns))
end

---@param column dbquery.Column
---@param relation dbquery.Relation
---@return string[]
local function describeColumn(column, relation)
  local lines = { "```sql", qualifiedName(relation) .. "." .. columnLine(column), "```" }
  if column.labels then
    vim.list_extend(lines, { "", "values: " .. table.concat(column.labels, ", ") })
  end
  comment(lines, column.comment)
  return lines
end

---@param relation dbquery.Relation
---@return string[]
local function describeRelation(relation)
  local lines = { "```sql", relation.kind .. " " .. qualifiedName(relation) }
  for _, line in ipairs(columnTable(relation.columns)) do
    lines[#lines + 1] = "  " .. line
  end
  lines[#lines + 1] = "```"
  comment(lines, relation.comment)
  return lines
end

---@param dialect dbquery.Dialect
---@param functions dbquery.Function[]
---@return string[]
local function describeFunctions(dialect, functions)
  local lines = {}
  for _, fn in ipairs(functions) do
    local args = vim.tbl_map(function(arg)
      return joined(" ", arg.mode ~= "in" and arg.mode or nil, arg.name, arg.type)
    end, describe.passed(fn))
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    local signature = fn.kind .. " " .. (fn.schema and (fn.schema .. ".") or "") .. fn.name
      .. "(" .. table.concat(args, ", ") .. ")"
    local result = describe.result(dialect, fn) or {}
    lines[#lines + 1] = "```sql"
    lines[#lines + 1] = signature .. (result[1] and (" → " .. result[1]) or "")
    vim.list_extend(lines, result, 2)
    lines[#lines + 1] = "```"
    comment(lines, fn.comment)
  end
  return lines
end

--- Returns, as markdown, the column, table, or function overloads the catalog
--- holds under the word in `context`, or nil when the catalog holds none.
---@param opened dbquery.Opened
---@param context dbquery.CursorContext
---@return lsp.Hover|nil
function M.hover(opened, context)
  local found = target.at(opened, context)
  if not found then
    return nil
  end
  local lines
  if found.kind == "column" then
    lines = describeColumn(found.column, found.relation)
  elseif found.kind == "relation" then
    lines = describeRelation(found.relation)
  else
    lines = describeFunctions(opened.document.dialect, found.functions)
  end
  return { contents = { kind = "markdown", value = table.concat(lines, "\n") } }
end

return M
