--[[
What the cursor is in, for completion, hover, and signature help.

`at` returns a `dbquery.CursorContext`: the word under the cursor, what kind of
name belongs there, the relations in scope, the function call and argument the
cursor is in, and the insert column list or values row it is in. The text may
be half typed. A group the statement leaves open before the cursor is closed
where the next clause starts, so the rest of the statement still counts.

Inside a `do` block or a function body, the body is read as its own sql, with
the function's parameters and declared variables in scope.
]]

local body = require("db-query.sql.body")
local lex = require("db-query.sql.lex")
local role = require("db-query.sql.role")
local scope = require("db-query.sql.scope")
local statements = require("db-query.sql.statements")
local syntax = require("db-query.sql.syntax")

local M = {}

---@alias dbquery.CursorKind
---| "none" Inside a string, comment, client command, or dollar quote that is not a body.
---| "keyword" Where the next word is a keyword, such as after a table's alias.
---| "relation" Where a table goes.
---| "column" Where an expression goes.
---| "qualified" After `name.`, where a column of that relation goes.
---| "insert_columns" In the column list of an insert.
---| "columns_of" In a column list of a named table, such as `create index on t (`.

---@class dbquery.Word
---@field text string The whole identifier under the cursor, or "" when the cursor is between tokens.
---@field first integer Byte offset of its first character.
---@field last integer Byte offset of its last character, `first - 1` when empty.

---@class dbquery.Call
---@field name string Dotted function name as written.
---@field argument integer Which argument the cursor is in, counting from 1.

---@class dbquery.InsertPosition
---@field table string Dotted name as written.
---@field list "columns"|"values"
---@field position integer Which entry of the list the cursor is in, counting from 1.
---@field columns string[]|nil The insert's column list, when one is written.

--- Sql text and its tokens, read by the rules of one dialect.
---@class dbquery.Document
---@field dialect dbquery.Dialect
---@field text string Usually a whole buffer.
---@field tokens dbquery.Token[] Every token of `text`, so text lexed once serves every request against it.

---@class dbquery.CursorContext
---@field kind dbquery.CursorKind
---@field word dbquery.Word
---@field prefix string The part of `word` before the cursor.
---@field qualifier string|nil The dotted name before `.`, for kind "qualified".
---@field clause dbquery.Clause|nil The clause holding the cursor, when it is in a statement, a query block, or a filter, over, or within group clause.
---@field call dbquery.Call|nil The innermost function call holding the cursor.
---@field insert dbquery.InsertPosition|nil
---@field columnsOf string|nil The table, for kind "columns_of".
---@field scope dbquery.ScopeRelation[] Innermost query block first.

--- Returns the table named by `alter table <name>` at the start of `items`.
---@param items dbquery.Token[]
---@return string|nil
local function alteredTable(items)
  if not (lex.isWord(items[1], "alter") and lex.isWord(items[2], "table")) then
    return nil
  end
  local index = 3
  while lex.isWord(items[index], "if") or lex.isWord(items[index], "exists") or lex.isWord(items[index], "only") do
    index = index + 1
  end
  return (syntax.nameAt(items, index))
end

--- Returns the table a `create` or `alter` statement names after `on`, such as
--- the table of `create policy p on t`.
---@param items dbquery.Token[]
---@return dbquery.ScopeRelation|nil
local function ddlTable(items)
  if not (lex.isWord(items[1], "create") or lex.isWord(items[1], "alter")) then
    return nil
  end
  for index, item in ipairs(items) do
    if lex.isWord(item, "on") and syntax.isName(items[index + 1]) then
      return { kind = "table", name = (syntax.nameAt(items, index + 1)) }
    end
  end
  return nil
end

--- Returns the kind of name that belongs at `index` of a statement or query block.
---@param group dbquery.Group
---@param index integer
---@param clause dbquery.Clause
---@return dbquery.CursorKind
local function kindIn(group, index, clause)
  local items = group.items
  if scope.namesRelations(clause) then
    local at = index - 1
    while at >= 1 and not scope.startsFromItem(group.dialect, items[at]) and not lex.isWord(items[at], "on") do
      at = at - 1
    end
    if at >= 1 and lex.isWord(items[at], "on") then
      return "column"
    end
    return at == index - 1 and "relation" or "keyword"
  end
  if clause == "start" or clause == "with" or clause == "setop" then
    return "keyword"
  end
  return "column"
end

--- Points each table named like a CTE at that CTE, in `relations` and in the
--- sources of every subquery and CTE they reach. A CTE's own sources are left
--- alone where they name the CTE itself, which in a query that is not
--- recursive means the real table.
---@param relations dbquery.ScopeRelation[]
local function resolveCtes(relations)
  local ctes, seen = {}, {}
  local function collect(list)
    for _, relation in ipairs(list) do
      if not seen[relation] then
        seen[relation] = true
        if relation.kind == "cte" and not ctes[relation.name:lower()] then
          ctes[relation.name:lower()] = relation
        end
        collect(relation.sources or {})
      end
    end
  end
  collect(relations)

  local resolved = {}
  local function resolve(list, owner)
    for _, relation in ipairs(list) do
      local name = relation.kind == "table" and not relation.name:find(".", 1, true) and relation.name:lower()
      local cte = name and name ~= owner and ctes[name]
      if cte then
        relation.kind = "cte"
        relation.columns = relation.columns or cte.columns
        relation.sources = cte.sources
      end
      if relation.sources and not resolved[relation.sources] then
        resolved[relation.sources] = true
        resolve(relation.sources, relation.kind == "cte" and relation.name:lower() or owner)
      end
    end
  end
  resolve(relations, nil)
end

--- Returns the code tokens of the statement holding `cursor`, with a cursor
--- token in place of the identifier under it, and that identifier. Inside a
--- block such as a `begin atomic` body, the statement is the body's own
--- statement.
---@param dialect dbquery.Dialect
---@param tokens dbquery.Token[] Every token of the text.
---@param cursor integer
---@return dbquery.Token[] statement
---@return dbquery.Word word
local function cursorStatement(dialect, tokens, cursor)
  local marker = syntax.marker("cursor", cursor)
  local word = { text = "", first = cursor, last = cursor - 1 }
  local placed, withMarker = false, {}
  -- Client commands stay until the statements are split, because some of
  -- them end a statement.
  for _, token in ipairs(tokens) do
    local under = lex.isIdentifier(token) and token.first < cursor and cursor <= token.last + 1
    if not placed and (under or token.first >= cursor) then
      withMarker[#withMarker + 1] = marker
      placed = true
      if under then
        word = { text = token.text, first = token.first, last = token.last }
      end
    end
    if token.kind ~= "comment" and not under then
      withMarker[#withMarker + 1] = token
    end
  end
  if not placed then
    withMarker[#withMarker + 1] = marker
  end

  for _, statement in ipairs(statements.split(dialect, withMarker)) do
    if vim.list_contains(statement, marker) then
      return body.innerStatement(dialect, lex.code(statement), marker), word
    end
  end
  error("the cursor token belongs to no statement")
end

--- Returns the context at `cursor`, which is outside every string, comment,
--- and dollar quote.
---@param document dbquery.Document
---@param cursor integer
---@return dbquery.CursorContext
local function analyze(document, cursor)
  local statement, word = cursorStatement(document.dialect, document.tokens, cursor)
  local root, cursorGroup, cursorIndex = syntax.groups(document.dialect, statement)
  local context = { kind = "column", word = word, prefix = word.text:sub(1, cursor - word.first), scope = {} }

  local group, index = cursorGroup, cursorIndex
  while group do
    local what = role.of(group)
    local items = group.items

    if group == cursorGroup then
      local previous = items[index - 1]
      if what.role == "insert_columns" or what.role == "values_row" then
        local list = what.role == "insert_columns" and "columns" or "values"
        context.insert = { table = what.insert.table, list = list, position = syntax.position(items, index), columns = what.insert.columns }
        context.kind = list == "columns" and "insert_columns" or "column"
      elseif what.role == "columns_of" then
        context.kind, context.columnsOf = "columns_of", what.table
      elseif what.role == "statement" or what.role == "query" or what.role == "clause" then
        context.clause = syntax.clauses(group)[index]
        local altered = context.clause == "start" and alteredTable(items)
        local columnWord = lex.isWord(previous, "column") or lex.isWord(previous, "drop") or lex.isWord(previous, "rename")
        if altered and columnWord then
          context.kind, context.columnsOf = "columns_of", altered
        else
          context.kind = kindIn(group, index, context.clause)
        end
      end
      if previous and previous.kind == "." and lex.isIdentifier(items[index - 2]) then
        context.kind, context.qualifier = "qualified", (syntax.nameBefore(items, index - 2))
      end
    end

    if what.role == "call" and not context.call then
      context.call = { name = (syntax.nameBefore(group.parent.items, group.index - 1)), argument = syntax.position(items, index) }
    end

    if what.role == "statement" or what.role == "query" then
      local clauses, blocks = syntax.clauses(group)
      vim.list_extend(context.scope, scope.relations(group, clauses, blocks, blocks[index]))
      local target = scope.insertTarget(group)
      local conflict = false
      for at = 1, index do
        conflict = conflict or clauses[at] == "conflict"
      end
      if target and conflict and clauses[index] ~= "returning" then
        context.scope[#context.scope + 1] = { kind = "table", name = target.table, alias = "excluded" }
      end
      vim.list_extend(context.scope, scope.ctes(items, clauses))
      local ddl = group == root and ddlTable(items)
      if ddl then
        context.scope[#context.scope + 1] = ddl
      end
    end

    index = group.index
    group = group.parent
  end

  resolveCtes(context.scope)
  return context
end

--- Returns the context at byte offset `cursor` of `document`.
---@param document dbquery.Document
---@param cursor integer Byte offset the cursor is before, counting from 1.
---@return dbquery.CursorContext
function M.at(document, cursor)
  local inside = body.at(document, cursor)
  if inside then
    local dialect = document.dialect
    local nested = { dialect = dialect, text = inside.text, tokens = lex.tokens(dialect, inside.text) }
    local context = M.at(nested, cursor - inside.offset)
    context.word.first = context.word.first + inside.offset
    context.word.last = context.word.last + inside.offset
    if context.kind ~= "none" then
      vim.list_extend(context.scope, inside.variables)
    end
    return context
  end
  if body.inLiteral(document.tokens, cursor) then
    return { kind = "none", word = { text = "", first = cursor, last = cursor - 1 }, prefix = "", scope = {} }
  end
  return analyze(document, cursor)
end

return M
