--[[
Finds the columns each relation in a statement's scope offers, and the names
that refer to those relations.
]]

local describe = require("db-query.lsp.describe")
local names = require("db-query.lsp.names")

local M = {}

--- Returns the name a scope relation is referred to by, which is its alias or
--- else the last part of its name.
---@param dialect dbquery.Dialect
---@param relation dbquery.ScopeRelation
---@return string|nil
function M.reference(dialect, relation)
  if relation.alias then
    return names.parts(dialect, relation.alias)[1].text
  end
  if relation.name then
    local parts = names.parts(dialect, relation.name)
    return parts[#parts].text
  end
  return nil
end

--- Returns true when `name`, as sql writes it, refers to the scope relation
--- `relation`.
---@param dialect dbquery.Dialect
---@param relation dbquery.ScopeRelation
---@param name string
---@return boolean
function M.refersTo(dialect, relation, name)
  local parts = names.parts(dialect, name)
  if relation.alias then
    return #parts == 1 and names.matches(dialect, parts[1], M.reference(dialect, relation), true)
  end
  if not relation.name then
    return false
  end
  local own = names.parts(dialect, relation.name)
  if #parts > #own then
    return false
  end
  for offset = 0, #parts - 1 do
    if not names.matches(dialect, parts[#parts - offset], own[#own - offset].text, true) then
      return false
    end
  end
  return true
end

--- Returns a column the catalog does not record, such as a CTE's, which may
--- hold null.
---@param name string
---@param columnType string|nil
---@return dbquery.Column
local function derivedColumn(name, columnType)
  return { name = name, type = columnType, nullable = true, hidden = false }
end

--- Returns the columns a function in from returns, from the first overload
--- whose declaration says what they are. Those are its table and out
--- arguments, the table, view, or composite type it returns a set of, or the
--- one column of a scalar result, named for the relation.
---@param catalog dbquery.Catalog
---@param dialect dbquery.Dialect
---@param relation dbquery.ScopeRelation
---@return dbquery.Column[]
local function functionColumns(catalog, dialect, relation)
  for _, fn in ipairs(names.functions(catalog, dialect, relation.name)) do
    local outputs = describe.returned(fn)
    if #outputs > 0 then
      return vim.tbl_map(function(arg)
        return derivedColumn(arg.name, arg.type)
      end, outputs)
    end

    local resultType = fn.result and (fn.result:match("^SETOF%s+(.+)$") or fn.result)
    if resultType and resultType ~= "record" and not resultType:match("^TABLE%s*%(") then
      local returnedRelation = names.relation(catalog, dialect, resultType)
      if returnedRelation then
        return returnedRelation.columns
      end
      local composite = names.type(catalog, dialect, resultType)
      if composite and composite.columns then
        return composite.columns
      end
      return { derivedColumn(M.reference(dialect, relation) or fn.name, resultType) }
    end
  end
  return {}
end

--- Returns the columns `relation` offers, in order. A table's come from the
--- catalog, and a function's from its declaration. A subquery's or CTE's are
--- the names its select gives, with `*` standing for the columns of what that
--- select reads.
---@param catalog dbquery.Catalog|nil
---@param dialect dbquery.Dialect
---@param relation dbquery.ScopeRelation
---@param seen table<dbquery.ScopeRelation, true>|nil Relations already being expanded, which a recursive CTE reaches again.
---@return dbquery.Column[]
function M.of(catalog, dialect, relation, seen)
  seen = seen or {}
  if seen[relation] then
    return {}
  end
  seen[relation] = true

  if relation.kind == "table" and not relation.columns then
    local catalogRelation = catalog and relation.name and names.relation(catalog, dialect, relation.name)
    return catalogRelation and catalogRelation.columns or {}
  end
  if relation.kind == "function" and not relation.columns then
    return catalog and relation.name and functionColumns(catalog, dialect, relation) or {}
  end
  local columns = {}
  for _, name in ipairs(relation.columns or {}) do
    if name == "*" then
      for _, source in ipairs(relation.sources or {}) do
        vim.list_extend(columns, M.of(catalog, dialect, source, seen))
      end
    else
      columns[#columns + 1] = derivedColumn(names.parts(dialect, name)[1].text)
    end
  end
  return columns
end

--- Returns the column a dotted name refers to among the relations in `scope`,
--- or nil when none of them offers it.
---@param catalog dbquery.Catalog|nil
---@param dialect dbquery.Dialect
---@param scope dbquery.ScopeRelation[]
---@param name string
---@return dbquery.Column|nil
function M.find(catalog, dialect, scope, name)
  local parts = names.parts(dialect, name)
  local qualifier = parts[#parts - 1]
  for _, relation in ipairs(scope) do
    if qualifier == nil or names.matches(dialect, qualifier, M.reference(dialect, relation), true) then
      for _, column in ipairs(M.of(catalog, dialect, relation)) do
        if names.matches(dialect, parts[#parts], column.name, true) then
          return column
        end
      end
    end
  end
  return nil
end

return M
