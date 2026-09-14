--[[
The relations a query block can refer to.

- `relations` reads the items of a from, join, using, or write-target clause:
  tables, functions, subqueries, and parenthesized joins, with their aliases.
- `ctes` reads the common table expressions a `with` clause defines.
- `insertTarget` finds the table and column list an insert writes to.
]]

local columns = require("db-query.sql.columns")
local lex = require("db-query.sql.lex")
local syntax = require("db-query.sql.syntax")

local M = {}

---@alias dbquery.RelationKind
---| "table"
---| "function" A set-returning function in from.
---| "subquery"
---| "cte"
---| "join" A parenthesized join given its own alias.
---| "variable" A function parameter or plpgsql variable.
---| "trigger_row" `new` or `old` in a trigger function.

---@class dbquery.Relation
---@field kind dbquery.RelationKind
---@field name string|nil Dotted name as written, for a table, function, or CTE.
---@field alias string|nil
---@field columns string[]|nil Columns the statement names itself, from an alias list or a select list. `*` stands for every column of `sources`.
---@field sources dbquery.Relation[]|nil For a subquery or CTE, the relations its select reads.

---@class dbquery.InsertTarget
---@field table string Dotted name as written.
---@field columns string[]|nil The column list, when one is written.
---@field columnGroup dbquery.Group|nil The group holding that column list.

local TARGETS = { from = true, update_target = true, delete_target = true, insert_target = true, merge_target = true }
local SKIPPED = {
  from = true, join = true, inner = true, left = true, right = true, full = true, outer = true, cross = true,
  natural = true, lateral = true, only = true, into = true, update = true, delete = true, using = true,
  merge = true, insert = true,
}
local JOINS = { join = true, inner = true, left = true, right = true, full = true, cross = true, natural = true }

--- Returns true when `clause` names relations.
---@param clause dbquery.Clause
---@return boolean
function M.namesRelations(clause)
  return TARGETS[clause] == true
end

--- Returns true for a word that separates one from item from the next.
---@param item dbquery.Token
---@return boolean
function M.startsFromItem(item)
  return item.kind == "," or (item.kind == "word" and SKIPPED[item.lower] == true)
end

--- Returns the relations the first select of `group` reads.
---@param group dbquery.Group
---@return dbquery.Relation[]
local function sources(group)
  local clauses, blocks = syntax.clauses(group.items)
  local found = M.relations(group.items, clauses, blocks, 1)
  vim.list_extend(found, M.ctes(group.items, clauses))
  return found
end

--- Reads the from item at `items[index]`, a table, function, subquery, or
--- parenthesized join with its alias. Returns the relations that item puts in
--- scope and the index of the item after it.
---@param items dbquery.Token[]
---@param index integer
---@param clause dbquery.Clause
---@return dbquery.Relation[]
---@return integer
local function fromItem(items, index, clause)
  local found, relation, at = {}, nil, index
  local item = items[at]

  if syntax.isGroup(item) then
    local word = syntax.firstWord(item.group)
    if word and syntax.QUERY[word] then
      relation = { kind = "subquery", columns = columns.outputs(item.group), sources = sources(item.group) }
    else
      local inner = item.group.items
      local clauses, blocks = {}, {}
      for position = 1, #inner do
        clauses[position], blocks[position] = "from", 1
      end
      vim.list_extend(found, M.relations(inner, clauses, blocks, 1))
      relation = { kind = "join" }
    end
    at = at + 1
  else
    local name, after = syntax.nameAt(items, at)
    at = after
    if syntax.isGroup(items[at]) and clause ~= "insert_target" then
      relation = { kind = "function", name = name }
      at = at + 1
    else
      relation = { kind = "table", name = name }
      if syntax.isGroup(items[at]) then
        at = at + 1
      end
    end
  end

  if items[at] and items[at].kind == "operator" and items[at].text == "*" then
    at = at + 1
  end
  if lex.isWord(items[at], "tablesample") then
    at = at + 2
    if syntax.isGroup(items[at]) then
      at = at + 1
    end
    if lex.isWord(items[at], "repeatable") then
      at = at + 2
    end
  end
  if lex.isWord(items[at], "with") and lex.isWord(items[at + 1], "ordinality") then
    at = at + 2
  end

  local explicit = lex.isWord(items[at], "as")
  if explicit then
    at = at + 1
  end
  -- `insert into t (a, b)` has a column list where an alias would go.
  if (explicit or clause ~= "insert_target") and syntax.isName(items[at]) then
    relation.alias = items[at].text
    at = at + 1
    if syntax.isGroup(items[at]) then
      relation.columns = syntax.listNames(items[at].group)
      at = at + 1
    end
  end

  if relation.kind ~= "join" or relation.alias then
    found[#found + 1] = relation
  end
  return found, at
end

--- Returns the relations named by the items of block `block` whose clause
--- names relations.
---@param items dbquery.Token[]
---@param clauses dbquery.Clause[]
---@param blocks integer[]
---@param block integer
---@return dbquery.Relation[]
function M.relations(items, clauses, blocks, block)
  local found = {}
  local state, index = "item", 1
  while index <= #items do
    local item = items[index]
    if index > 1 and clauses[index] ~= clauses[index - 1] then
      state = "item"
    end

    if blocks[index] ~= block or not TARGETS[clauses[index]] or item.kind == "cursor" then
      index = index + 1
    elseif state == "item" then
      if M.startsFromItem(item) then
        index = index + 1
      elseif syntax.isGroup(item) or lex.isIdentifier(item) then
        local relations, after = fromItem(items, index, clauses[index])
        vim.list_extend(found, relations)
        state, index = "after", after
      else
        index = index + 1
      end
    else
      if item.kind == "," or (item.kind == "word" and JOINS[item.lower]) then
        state = "item"
      elseif state == "after" and lex.isWord(item, "on") then
        state = "condition"
      end
      index = index + 1
    end
  end
  return found
end

--- Returns the common table expressions defined by the `with` clause of `items`.
---@param items dbquery.Token[]
---@param clauses dbquery.Clause[]
---@return dbquery.Relation[]
function M.ctes(items, clauses)
  local found, index = {}, 1
  while index <= #items do
    if clauses[index] == "with" and syntax.isName(items[index]) then
      local name, at, listed = items[index].text, index + 1, nil
      if syntax.isGroup(items[at]) then
        listed = syntax.listNames(items[at].group)
        at = at + 1
      end
      if lex.isWord(items[at], "as") then
        at = at + 1
        if lex.isWord(items[at], "not") then
          at = at + 1
        end
        if lex.isWord(items[at], "materialized") then
          at = at + 1
        end
        if syntax.isGroup(items[at]) then
          local query = items[at].group
          found[#found + 1] = { kind = "cte", name = name, alias = name, columns = listed or columns.outputs(query), sources = sources(query) }
          index = at
        end
      end
    end
    index = index + 1
  end
  return found
end

--- Returns the table an insert in `group` writes to, or nil when `group` holds
--- no insert.
---@param group dbquery.Group
---@return dbquery.InsertTarget|nil
function M.insertTarget(group)
  local clauses = syntax.clauses(group.items)
  for index, item in ipairs(group.items) do
    if clauses[index] == "insert_target" and syntax.isName(item) then
      local name, after = syntax.nameAt(group.items, index)
      local target = { table = name }
      local list = group.items[after]
      if syntax.isGroup(list) then
        target.columns = syntax.listNames(list.group)
        target.columnGroup = list.group
      end
      return target
    end
  end
  return nil
end

return M
