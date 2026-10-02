--[[
Tells what a parenthesized group is to the statement around it, such as a
subquery, a function call, or an insert's column list.
]]

local lex = require("db-query.sql.lex")
local relations = require("db-query.sql.relations")
local syntax = require("db-query.sql.syntax")

local M = {}

---@class dbquery.PlainRole
---@field role "statement"|"query"|"clause"|"call"|"parens"

---@class dbquery.InsertRole
---@field role "insert_columns"|"values_row"
---@field insert dbquery.InsertTarget

---@class dbquery.ColumnsRole
---@field role "columns_of"
---@field table string

---@alias dbquery.Role dbquery.PlainRole|dbquery.InsertRole|dbquery.ColumnsRole

--- Returns the table whose column list `group` is, as in `create index on t (`,
--- `references t (`, or `copy t (`, or nil when it is none of those.
---@param group dbquery.Group
---@param parent dbquery.Group
---@return string|nil
local function listedTable(group, parent)
  local previous = parent.items[group.index - 1]
  if not syntax.isName(previous) then
    return nil
  end
  local name, first = syntax.nameBefore(parent.items, group.index - 1)
  local before = parent.items[first - 1]
  if lex.isWord(before, "using") then
    local usingTable, usingFirst = syntax.nameBefore(parent.items, first - 2)
    if usingTable then
      name, before = usingTable, parent.items[usingFirst - 1]
    end
  end
  if lex.isWord(before, "on") or lex.isWord(before, "references") or lex.isWord(before, "copy") then
    return name
  end
  return nil
end

--- Returns what `group` is to its parent.
---@param group dbquery.Group
---@return dbquery.Role
function M.of(group)
  local parent = group.parent
  if not parent then
    return { role = "statement" }
  end
  if syntax.startsQuery(group) then
    return { role = "query" }
  end

  local previous = parent.items[group.index - 1]
  local insertTarget = relations.insertTarget(parent)
  if insertTarget and group == insertTarget.columnGroup then
    return { role = "insert_columns", insert = insertTarget }
  end
  local within = lex.isWord(previous, "group") and lex.isWord(parent.items[group.index - 2], "within")
  if lex.isWord(previous, "filter") or lex.isWord(previous, "over") or within then
    return { role = "clause" }
  end
  local clauses = syntax.clauses(parent)
  local startsRow = lex.isWord(previous, "values") or (previous ~= nil and previous.kind == ",")
  if insertTarget and startsRow and clauses[group.index] == "values" then
    return { role = "values_row", insert = insertTarget }
  end

  local listed = clauses[group.index] ~= "from" and listedTable(group, parent)
  if listed then
    return { role = "columns_of", table = listed }
  end
  local callableKeyword = previous ~= nil and previous.kind == "word" and group.dialect.callable[previous.lower]
  if group.open == "(" and (syntax.isName(previous) or callableKeyword) then
    return { role = "call" }
  end
  return { role = "parens" }
end

return M
