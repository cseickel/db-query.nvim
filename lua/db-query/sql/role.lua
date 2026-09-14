--[[
What a parenthesized group is to the statement around it: a subquery, a
function call, an insert's column list or values row, a column list of a named
table, or the inside of a filter, over, or within group clause.
]]

local lex = require("db-query.sql.lex")
local scope = require("db-query.sql.scope")
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

--- Keywords that are also function names.
local CALLABLE_KEYWORDS = { left = true, right = true, any = true, some = true, exists = true }

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
    local table, tableFirst = syntax.nameBefore(parent.items, first - 2)
    if table then
      name, before = table, parent.items[tableFirst - 1]
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
  local word = syntax.firstWord(group)
  if word and syntax.QUERY[word] then
    return { role = "query" }
  end

  local previous = parent.items[group.index - 1]
  local target = scope.insertTarget(parent)
  if target and group == target.columnGroup then
    return { role = "insert_columns", insert = target }
  end
  local within = lex.isWord(previous, "group") and lex.isWord(parent.items[group.index - 2], "within")
  if lex.isWord(previous, "filter") or lex.isWord(previous, "over") or within then
    return { role = "clause" }
  end
  local clauses = syntax.clauses(parent.items)
  local afterRow = previous ~= nil and previous.kind == "," and clauses[group.index] == "values"
  if target and (lex.isWord(previous, "values") or afterRow) then
    return { role = "values_row", insert = target }
  end

  local table = clauses[group.index] ~= "from" and listedTable(group, parent)
  if table then
    return { role = "columns_of", table = table }
  end
  local keyword = previous ~= nil and previous.kind == "word" and CALLABLE_KEYWORDS[previous.lower]
  if group.open == "(" and (syntax.isName(previous) or keyword) then
    return { role = "call" }
  end
  return { role = "parens" }
end

return M
