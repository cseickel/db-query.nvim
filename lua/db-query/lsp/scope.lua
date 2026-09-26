--[[
The relations a statement has in scope, matched against the catalog.

- `reference` and `refersTo` match a written name against a relation in scope.
- `columns` lists the columns a relation in scope offers.
- `scopeColumn` finds the catalog column a name refers to among them.
]]

local names = require("db-query.lsp.names")

local M = {}

--- Returns the name a scope relation is referred to by: its alias, or the last
--- part of its name.
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

--- Returns true when `written`, a name as sql writes it, refers to the scope
--- relation `relation`.
---@param dialect dbquery.Dialect
---@param relation dbquery.ScopeRelation
---@param written string
---@return boolean
function M.refersTo(dialect, relation, written)
  local parts = names.parts(dialect, written)
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

---@class dbquery.OfferedColumn
---@field name string
---@field column dbquery.Column|nil The catalog column, when the catalog records one.
---@field relation dbquery.Relation|nil The catalog relation the column belongs to.

---@param name string
---@param type string|nil
---@return dbquery.OfferedColumn
local function returned(name, type)
  return { name = name, column = { name = name, type = type, nullable = true, hidden = false } }
end

--- Returns the columns a function in from returns, from the first overload
--- whose declaration says what they are: its table and out arguments, the
--- table, view, or composite type it returns a set of, or the one column of a
--- scalar result, named for the relation.
---@param catalog dbquery.Catalog
---@param dialect dbquery.Dialect
---@param relation dbquery.ScopeRelation
---@return dbquery.OfferedColumn[]
local function functionColumns(catalog, dialect, relation)
  for _, fn in ipairs(names.functions(catalog, dialect, relation.name)) do
    local found = {}
    for _, argument in ipairs(fn.args) do
      local output = argument.mode == "table" or argument.mode == "out" or argument.mode == "inout"
      if output and argument.name then
        found[#found + 1] = returned(argument.name, argument.type)
      end
    end
    if #found > 0 then
      return found
    end

    local result = fn.result and (fn.result:match("^SETOF%s+(.+)$") or fn.result)
    if result and result ~= "record" and not result:match("^TABLE%s*%(") then
      local table = names.relation(catalog, dialect, result)
      if table then
        return vim.tbl_map(function(column)
          return { name = column.name, column = column, relation = table }
        end, table.columns)
      end
      local composite = names.type(catalog, dialect, result)
      if composite and composite.columns then
        return vim.tbl_map(function(column)
          return { name = column.name, column = column }
        end, composite.columns)
      end
      return { returned(M.reference(dialect, relation) or fn.name, result) }
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
---@return dbquery.OfferedColumn[]
function M.columns(catalog, dialect, relation, seen)
  seen = seen or {}
  if seen[relation] then
    return {}
  end
  seen[relation] = true

  local found = {}
  if relation.kind == "table" and not relation.columns then
    local table = catalog and relation.name and names.relation(catalog, dialect, relation.name)
    for _, column in ipairs(table and table.columns or {}) do
      found[#found + 1] = { name = column.name, column = column, relation = table }
    end
    return found
  end
  if relation.kind == "function" and not relation.columns then
    return catalog and relation.name and functionColumns(catalog, dialect, relation) or {}
  end
  for _, name in ipairs(relation.columns or {}) do
    if name == "*" then
      for _, source in ipairs(relation.sources or {}) do
        vim.list_extend(found, M.columns(catalog, dialect, source, seen))
      end
    else
      found[#found + 1] = { name = names.parts(dialect, name)[1].text }
    end
  end
  return found
end

--- Returns the catalog column a dotted name refers to among the relations in
--- `scope`, or nil when none of them offers it.
---@param catalog dbquery.Catalog
---@param dialect dbquery.Dialect
---@param scope dbquery.ScopeRelation[]
---@param written string
---@return dbquery.Column|nil
function M.scopeColumn(catalog, dialect, scope, written)
  local parts = names.parts(dialect, written)
  local qualifier = parts[#parts - 1]
  for _, relation in ipairs(scope) do
    if qualifier == nil or names.matches(dialect, qualifier, M.reference(dialect, relation), true) then
      for _, offered in ipairs(M.columns(catalog, dialect, relation)) do
        if offered.column and names.matches(dialect, parts[#parts], offered.name, true) then
          return offered.column
        end
      end
    end
  end
  return nil
end

return M
