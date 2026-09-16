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
---| "none" Inside a comment, client command, or dollar quote that is not a body.
---| "keyword" Where the next word is a keyword, such as after a table's alias.
---| "relation" Where a table goes.
---| "column" Where an expression goes.
---| "qualified" After `name.`, where a column of that relation goes.
---| "insert_columns" In the column list of an insert.
---| "columns_of" In a column list of a named table, such as `create index on t (`.
---| "literal" Inside a string, where the word is the text between the quotes.

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
---@field previous dbquery.Token|nil The code token before the word under the cursor, which a nested group stands in as one token.
---@field inCase boolean A `case` stands open before the cursor, so its `when`, `then`, `else`, and `end` may be written.
---@field afterCall boolean The cursor stands just after a call, where a window function's `over` may be written.
---@field opensValue boolean A value goes where the cursor stands, rather than a word reading the one before it.
---@field quote string|nil The character opening the string, for kind "literal".
---@field closed boolean A closing quote already stands at the end of the literal at the cursor.
---@field valueOf string|nil The dotted name of the column a literal at the cursor is compared to or written into.
---@field castTo string|nil The dotted name of the type a literal at the cursor is cast to.
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

--- Returns the value being typed in the string token `token`, which is the
--- text between its quotes on the line `cursor` is on. A string still being
--- typed has no closing quote and runs to the end of the text, which the
--- completion must not offer to replace.
---@param token dbquery.Token
---@param cursor integer
---@return dbquery.Word
local function quoted(token, cursor)
  local closed = not token.open
  local first = token.first + 1
  local text = token.text:sub(2, closed and -2 or -1)
  local opens = text:sub(1, cursor - first):find("\n[^\n]*$")
  if opens then
    first, text = first + opens, text:sub(opens + 1)
  end
  local ends = text:find("\n", 1, true)
  if ends then
    text = text:sub(1, ends - 1)
  end
  return { text = text, first = first, last = first + #text - 1 }
end

--- Returns the code tokens of the statement holding `cursor`, with a cursor
--- token in place of the identifier under it, and that identifier. Inside a
--- block such as a `begin atomic` body, the statement is the body's own
--- statement.
---@param dialect dbquery.Dialect
---@param tokens dbquery.Token[] Every token of the text.
---@param cursor integer
---@param literal dbquery.Token|nil The string holding the cursor, which the marker stands in for whole.
---@return dbquery.Token[] statement
---@return dbquery.Word word
local function cursorStatement(dialect, tokens, cursor, literal)
  local marker = syntax.marker("cursor", cursor)
  local word = { text = "", first = cursor, last = cursor - 1 }
  local placed, withMarker = false, {}
  -- Client commands stay until the statements are split, because some of
  -- them end a statement.
  for _, token in ipairs(tokens) do
    local under = token == literal
      or (literal == nil and lex.isIdentifier(token) and token.first < cursor and cursor <= token.last + 1)
    if not placed and (under or token.first >= cursor) then
      withMarker[#withMarker + 1] = marker
      placed = true
      if under then
        word = literal and quoted(token, cursor) or { text = token.text, first = token.first, last = token.last }
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

--- Words that may stand between a column and a value compared with it.
local COMPARISONS = {
  ["in"] = true, like = true, ilike = true, ["not"] = true, is = true, similar = true, to = true,
  glob = true, match = true, regexp = true, rlike = true, any = true, all = true, some = true,
  between = true,
}

--- Token kinds that leave a value unwritten, so the next word opens one.
local UNWRITTEN = { operator = true, cast = true, [","] = true }

--- Returns true when a value goes at `index`, rather than a word that reads
--- the value written before it. The `*` of `select *` ends a value, and the
--- `*` of `a * b` stands between two.
---@param dialect dbquery.Dialect
---@param items dbquery.Token[]
---@param index integer
---@return boolean
local function opensValue(dialect, items, index)
  local previous = items[index - 1]
  if previous == nil then
    return true
  end
  if previous.kind == "operator" and previous.text == "*" then
    local before = items[index - 2]
    return before ~= nil and not (lex.isWord(before, "select") or before.kind == "," or before.kind == ".")
  end
  if previous.kind == "word" then
    return previous.reserved and not (dialect.keywords.closes or {})[previous.lower]
  end
  return UNWRITTEN[previous.kind] == true
end

--- Returns the name of the column a value at `index` is compared to or written
--- into, reading back over the comparison that precedes it.
---@param items dbquery.Token[]
---@param index integer
---@return string|nil
local function comparedName(items, index)
  local at, compared = index - 1, false
  while items[at] ~= nil and (items[at].kind == "operator" or (items[at].kind == "word" and COMPARISONS[items[at].lower])) do
    compared, at = true, at - 1
  end
  return compared and (syntax.nameBefore(items, at)) or nil
end

--- Returns the name of the type a value at `index` is cast to, written either
--- as `'x'::mood` or as `cast('x' as mood)`.
---@param items dbquery.Token[]
---@param index integer
---@param call dbquery.Call|nil The call holding the cursor.
---@return string|nil
local function castName(items, index, call)
  local after = items[index + 1]
  if after == nil then
    return nil
  end
  if after.kind == "cast" then
    return (syntax.nameAt(items, index + 2))
  end
  local casting = call ~= nil and call.name:lower() == "cast" and call.argument == 1
  return casting and lex.isWord(after, "as") and (syntax.nameAt(items, index + 2)) or nil
end

--- Returns true when a `case` opened before `index` is still open there. A
--- `case` inside a nested group is closed within it, since that group stands
--- in `items` as one token.
---@param items dbquery.Token[]
---@param index integer
---@return boolean
local function openCase(items, index)
  local depth = 0
  for at = 1, index - 1 do
    if lex.isWord(items[at], "case") then
      depth = depth + 1
    elseif lex.isWord(items[at], "end") and depth > 0 then
      depth = depth - 1
    end
  end
  return depth > 0
end

--- Returns true when a query written at `index` of `group` cannot read the
--- relations `group` names: a CTE body, or a from item written without
--- `lateral`. A query anywhere else, such as one in a select list or a where
--- clause, reads them, which is what a correlated subquery does.
---@param group dbquery.Group
---@param clauses dbquery.Clause[]
---@param index integer
---@return boolean
local function hidesRelations(group, clauses, index)
  if clauses[index] == "with" then
    return true
  end
  return scope.namesRelations(clauses[index]) and not lex.isWord(group.items[index - 1], "lateral")
end

--- Returns the context at `cursor`, which is outside every comment and dollar
--- quote, and inside no string but `literal`.
---@param document dbquery.Document
---@param cursor integer
---@param literal dbquery.Token|nil The string holding the cursor.
---@return dbquery.CursorContext
local function analyze(document, cursor, literal)
  local statement, word = cursorStatement(document.dialect, document.tokens, cursor, literal)
  local root, cursorGroup, cursorIndex = syntax.groups(document.dialect, statement)
  local context =
    { kind = "column", word = word, prefix = word.text:sub(1, cursor - word.first), scope = {}, inCase = false, afterCall = false, closed = false, opensValue = true }

  local group, index = cursorGroup, cursorIndex
  -- `fromQuery` is true once the walk leaves a query, through any parentheses
  -- written around it, so the group holding that query decides what it reads.
  local relationsVisible, fromQuery = true, false
  local child = nil
  while group do
    local what = role.of(group)
    local items = group.items

    if group == cursorGroup then
      local previous = items[index - 1]
      context.previous = previous
      context.opensValue = opensValue(document.dialect, items, index)
      context.inCase = openCase(items, index)
      context.afterCall = syntax.isGroup(previous) and role.of(previous.group).role == "call"
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
      if literal then
        context.valueOf = comparedName(items, index)
      end
    end

    if what.role == "call" and not context.call then
      context.call = { name = (syntax.nameBefore(group.parent.items, group.index - 1)), argument = syntax.position(items, index) }
    end

    if literal and group == cursorGroup then
      context.castTo = castName(items, index, context.call)
    end

    -- A value in a list, as in `status in ('a', 'b')`, is compared by the
    -- words written before the list.
    if literal and context.valueOf == nil and child == cursorGroup then
      context.valueOf = comparedName(items, index)
    end

    if what.role == "statement" or what.role == "query" then
      local clauses, blocks = syntax.clauses(group)
      if fromQuery and hidesRelations(group, clauses, index) then
        relationsVisible = false
      end
      if relationsVisible then
        vim.list_extend(context.scope, scope.relations(group, clauses, blocks, blocks[index]))
        local target = scope.insertTarget(group)
        local conflict = false
        for at = 1, index do
          conflict = conflict or clauses[at] == "conflict"
        end
        if target and conflict and clauses[index] ~= "returning" then
          context.scope[#context.scope + 1] = { kind = "table", name = target.table, alias = "excluded" }
        end
        local ddl = group == root and ddlTable(items)
        if ddl then
          context.scope[#context.scope + 1] = ddl
        end
      end
      vim.list_extend(context.scope, scope.ctes(items, clauses))
    end

    if what.role == "query" then
      fromQuery = true
    elseif what.role ~= "parens" then
      fromQuery = false
    end

    child, index = group, group.index
    group = group.parent
  end

  resolveCtes(context.scope)
  if literal then
    context.kind = "literal"
    context.quote = literal.text:sub(1, 1)
    context.closed = not literal.open
  end
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
  local literal = body.stringAt(document.tokens, cursor)
  if literal == nil and body.inLiteral(document.tokens, cursor) then
    return {
      kind = "none",
      word = { text = "", first = cursor, last = cursor - 1 },
      prefix = "",
      scope = {},
      inCase = false,
      afterCall = false,
      closed = false,
      opensValue = true,
    }
  end
  return analyze(document, cursor, literal)
end

return M
