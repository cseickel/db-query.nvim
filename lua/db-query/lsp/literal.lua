--[[
The values a string written at the cursor may hold.

An enum column accepts a fixed set of labels, and the catalog records those
labels on the type and on every column of that type. A cast names the type
outright. Otherwise the column the string is compared to, or the column it is
written into, names it.
]]

local names = require("db-query.lsp.names")

local M = {}

--- Returns the values the string at the cursor may hold, or nil when the
--- catalog holds no fixed set for it.
---@param opened dbquery.Opened
---@param context dbquery.CursorContext
---@return string[]|nil
function M.labels(opened, context)
  local catalog, dialect = opened.catalog, opened.document.dialect
  if catalog == nil then
    return nil
  end

  if context.castTo then
    local found = names.type(catalog, dialect, context.castTo)
    return found and found.labels or nil
  end

  if context.valueOf then
    local column = names.scopeColumn(catalog, dialect, context.scope, context.valueOf)
    return column and column.labels or nil
  end

  local insert = context.insert
  local written = insert and insert.list == "values" and insert.columns and insert.columns[insert.position]
  if written then
    local target = { { kind = "table", name = insert.table } }
    local column = names.scopeColumn(catalog, dialect, target, written)
    return column and column.labels or nil
  end
  return nil
end

return M
