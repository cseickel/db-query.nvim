--[[
The catalog object the word under the cursor names: a column, a relation, or a
function's overloads.
]]

local names = require("db-query.lsp.names")
local scope = require("db-query.lsp.columns")

local M = {}

---@alias dbquery.Target
---| { kind: "column", column: dbquery.Column, relation: dbquery.Relation }
---| { kind: "relation", relation: dbquery.Relation }
---| { kind: "functions", functions: dbquery.Function[] }

--- Returns the column `word` names among the columns `relation` offers, when
--- the catalog knows it.
---@param opened dbquery.Opened
---@param relation dbquery.ScopeRelation
---@param word string
---@return dbquery.Target|nil
local function scopeColumn(opened, relation, word)
  local dialect = opened.document.dialect
  local part = names.parts(dialect, word)[1]
  for _, offered in ipairs(scope.columns(opened.catalog, dialect, relation)) do
    if offered.column and offered.relation and offered.name:lower() == part.text:lower() then
      return { kind = "column", column = offered.column, relation = offered.relation }
    end
  end
  return nil
end

---@param opened dbquery.Opened
---@param name string
---@param calls boolean The name is followed by `(`.
---@return dbquery.Target|nil
local function catalogName(opened, name, calls)
  local catalog, dialect = opened.catalog, opened.document.dialect
  local relation = not calls and names.relation(catalog, dialect, name)
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
  local calls = opened.document.text:sub(context.word.last + 1):match("^%s*%(") ~= nil

  if context.kind == "qualified" then
    for _, relation in ipairs(context.scope) do
      if scope.refersTo(dialect, relation, context.qualifier) and #scope.columns(catalog, dialect, relation) > 0 then
        return scopeColumn(opened, relation, word)
      end
    end
    return scopeColumn(opened, { kind = "table", name = context.qualifier }, word)
      or catalogName(opened, context.qualifier .. "." .. word, calls)
  end
  if context.kind == "insert_columns" or context.kind == "columns_of" then
    local table = context.kind == "columns_of" and context.columnsOf or context.insert.table
    return scopeColumn(opened, { kind = "table", name = table }, word)
  end
  if context.kind == "relation" then
    return catalogName(opened, word, calls)
  end

  for _, relation in ipairs(context.scope) do
    if not calls and scope.reference(dialect, relation) and scope.refersTo(dialect, relation, word)
      and relation.kind == "table" and relation.name then
      local named = catalogName(opened, relation.name, false)
      if named then
        return named
      end
      break
    end
  end
  if not calls then
    for _, relation in ipairs(context.scope) do
      local found = scopeColumn(opened, relation, word)
      if found then
        return found
      end
    end
  end
  return catalogName(opened, word, calls)
end

return M
