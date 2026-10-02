--[[
Finds the catalog object the word under the cursor names, which is a column, a
relation, or a function's overloads.
]]

local columns = require("db-query.lsp.columns")
local names = require("db-query.lsp.names")

local M = {}

---@alias dbquery.Target
---| { kind: "column", column: dbquery.Column, relation: dbquery.Relation }
---| { kind: "relation", relation: dbquery.Relation }
---| { kind: "functions", functions: dbquery.Function[] }

--- Returns the column `word` names among the columns `relation` offers, when
--- it is a column of a catalog relation.
---@param opened dbquery.Opened
---@param relation dbquery.ScopeRelation
---@param word string
---@return dbquery.Target|nil
local function columnTarget(opened, relation, word)
  local catalog = opened.catalog
  local column = catalog and columns.find(catalog, opened.document.dialect, { relation }, word)
  local owner = column and vim.iter(catalog.relations):find(function(candidate)
    return vim.tbl_contains(candidate.columns, column)
  end)
  return owner and { kind = "column", column = column, relation = owner } or nil
end

---@param opened dbquery.Opened
---@param name string
---@param isCall boolean The name is followed by `(`.
---@return dbquery.Target|nil
local function catalogName(opened, name, isCall)
  local catalog, dialect = opened.catalog, opened.document.dialect
  if not catalog then
    return nil
  end
  local relation = not isCall and names.relation(catalog, dialect, name)
  if relation then
    return { kind = "relation", relation = relation }
  end
  local functions = names.functions(catalog, dialect, name)
  return #functions > 0 and { kind = "functions", functions = functions } or nil
end

--- Returns what the word in `context` names in the catalog, or nil when the
--- catalog holds nothing by that name.
---@param opened dbquery.Opened
---@param context dbquery.CursorContext
---@return dbquery.Target|nil
function M.at(opened, context)
  local word, catalog = context.word.text, opened.catalog
  if word == "" or not catalog then
    return nil
  end
  local dialect = opened.document.dialect
  local isCall = opened.document.text:sub(context.word.last + 1):match("^%s*%(") ~= nil

  if context.kind == "qualified" then
    for _, relation in ipairs(context.scope) do
      if columns.refersTo(dialect, relation, context.qualifier) and #columns.of(catalog, dialect, relation) > 0 then
        return columnTarget(opened, relation, word)
      end
    end
    return columnTarget(opened, { kind = "table", name = context.qualifier }, word)
      or catalogName(opened, context.qualifier .. "." .. word, isCall)
  end
  if context.kind == "insert_columns" or context.kind == "columns_of" then
    local tableName = context.kind == "columns_of" and context.columnsOf or context.insert.table
    return columnTarget(opened, { kind = "table", name = tableName }, word)
  end
  if context.kind == "relation" then
    return catalogName(opened, word, isCall)
  end

  for _, relation in ipairs(context.scope) do
    if not isCall and relation.kind == "table" and relation.name and columns.refersTo(dialect, relation, word) then
      local named = catalogName(opened, relation.name, false)
      if named then
        return named
      end
      break
    end
  end
  if not isCall then
    for _, relation in ipairs(context.scope) do
      local column = columnTarget(opened, relation, word)
      if column then
        return column
      end
    end
  end
  return catalogName(opened, word, isCall)
end

return M
