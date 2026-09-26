--[[
The relations a query block can refer to.

- `relations` reads the items of a from, join, using, or write-target clause:
  tables, functions, subqueries, and parenthesized joins, with their aliases.
- `ctes` reads the common table expressions a `with` clause defines.
- `insertTarget` finds the table and column list an insert writes to.
]]

local columns = require("db-query.sql.columns")
local dialects = require("db-query.sql.dialect")
local lex = require("db-query.sql.lex")
local syntax = require("db-query.sql.syntax")

local M = {}

---@alias dbquery.ScopeRelationKind
---| "table"
---| "function" A set-returning function in from.
---| "subquery"
---| "cte"
---| "join" A parenthesized join given its own alias.
---| "variable" A function parameter or plpgsql variable.
---| "trigger_row" `new` or `old` in a trigger function.

---@class dbquery.ScopeRelation
---@field kind dbquery.ScopeRelationKind
---@field name string|nil Dotted name as written, for a table, function, or CTE.
---@field alias string|nil
---@field columns string[]|nil Columns the statement names itself, from an alias list or a select list. `*` stands for every column of `sources`.
---@field sources dbquery.ScopeRelation[]|nil For a subquery or CTE, the relations its select reads.

---@class dbquery.InsertTarget
---@field table string Dotted name as written.
---@field columns string[]|nil The column list, when one is written.
---@field columnGroup dbquery.Group|nil The group holding that column list.

local TARGETS = { from = true, update_target = true, delete_target = true, insert_target = true, merge_target = true }

--- Returns true when `clause` names relations.
---@param clause dbquery.Clause
---@return boolean
function M.namesRelations(clause)
  return TARGETS[clause] == true
end

--- Returns true for a word that separates one from item from the next.
---@param dialect dbquery.Dialect
---@param item dbquery.Token
---@return boolean
function M.startsFromItem(dialect, item)
  if item.kind == "," then
    return true
  end
  return item.kind == "word" and (dialect.beforeRelation[item.lower] == true or dialect.joins[item.lower] == true)
end

--- Returns the relations the first select of `group` reads.
---@param group dbquery.Group
---@return dbquery.ScopeRelation[]
local function sources(group)
  local clauses, blocks = syntax.clauses(group)
  local found = M.relations(group, clauses, blocks, 1)
  vim.list_extend(found, M.ctes(group.items, clauses))
  return found
end

---@param part dbquery.PatternPart
---@param item dbquery.Token|nil
---@return boolean
local function matchesPart(part, item)
  if part == dialects.GROUP then
    return syntax.isGroup(item)
  end
  if item == nil or item.kind ~= "word" then
    return false
  end
  if part == dialects.ANY then
    return true
  end
  if type(part) == "table" then
    return part[item.lower] == true
  end
  return item.lower == part
end

--- Returns the index after the dialect's from suffixes that start at
--- `items[at]`, such as `tablesample system (10)`, or `at` when none do.
---@param dialect dbquery.Dialect
---@param items dbquery.Token[]
---@param at integer
---@return integer
local function skipSuffixes(dialect, items, at)
  local skipped = true
  while skipped do
    skipped = false
    for _, pattern in ipairs(dialect.fromSuffixes) do
      local position = at
      for _, part in ipairs(pattern) do
        if not (position and matchesPart(part, items[position])) then
          position = nil
          break
        end
        position = position + 1
      end
      if position then
        at, skipped = position, true
        break
      end
    end
  end
  return at
end

--- Reads the from item at `group.items[index]`, a table, function, subquery,
--- or parenthesized join with its alias. Returns the relations that item puts
--- in scope and the index of the item after it.
---@param group dbquery.Group
---@param index integer
---@param clause dbquery.Clause
---@return dbquery.ScopeRelation[]
---@return integer
local function fromItem(group, index, clause)
  local items, dialect = group.items, group.dialect
  local found, relation, at = {}, nil, index
  local item = items[at]

  if syntax.isGroup(item) then
    if syntax.startsQuery(item.group) then
      relation = { kind = "subquery", columns = columns.outputs(item.group), sources = sources(item.group) }
    else
      local inner = item.group.items
      local clauses, blocks = {}, {}
      for position = 1, #inner do
        clauses[position], blocks[position] = "from", 1
      end
      vim.list_extend(found, M.relations(item.group, clauses, blocks, 1))
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
  at = skipSuffixes(dialect, items, at)

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
    at = skipSuffixes(dialect, items, at)
  end

  if relation.kind ~= "join" or relation.alias then
    found[#found + 1] = relation
  end
  return found, at
end

--- Returns the relations named by the items of `group` in union block
--- `block` whose clause names relations.
---@param group dbquery.Group
---@param clauses dbquery.Clause[]
---@param blocks integer[]
---@param block integer
---@return dbquery.ScopeRelation[]
function M.relations(group, clauses, blocks, block)
  local items, dialect = group.items, group.dialect
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
      if M.startsFromItem(dialect, item) then
        index = index + 1
      elseif syntax.isGroup(item) or lex.isIdentifier(item) then
        local relations, after = fromItem(group, index, clauses[index])
        vim.list_extend(found, relations)
        state, index = "after", after
      else
        index = index + 1
      end
    else
      if item.kind == "," or (item.kind == "word" and dialect.joins[item.lower]) then
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
---@return dbquery.ScopeRelation[]
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
  local clauses = syntax.clauses(group)
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
