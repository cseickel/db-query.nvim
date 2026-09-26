--[[
The values a string written at the cursor may hold.
]]

local columns = require("db-query.lsp.columns")
local names = require("db-query.lsp.names")

local M = {}

--- Returns the labels of the enum the string at the cursor is cast to,
--- compared to, or written into, or nil when the catalog holds no fixed set
--- for it.
---@param opened dbquery.Opened
---@param context dbquery.CursorContext
---@return string[]|nil
function M.labels(opened, context)
  local catalog, dialect = opened.catalog, opened.document.dialect
  if catalog == nil then
    return nil
  end

  if context.castTo then
    local castType = names.type(catalog, dialect, context.castTo)
    return castType and castType.labels or nil
  end

  if context.valueOf then
    local column = columns.find(catalog, dialect, context.scope, context.valueOf)
    return column and column.labels or nil
  end

  local insert = context.insert
  local columnName = insert and insert.list == "values" and insert.columns and insert.columns[insert.position]
  if columnName then
    local insertTable = { { kind = "table", name = insert.table } }
    local column = columns.find(catalog, dialect, insertTable, columnName)
    return column and column.labels or nil
  end
  return nil
end

return M
