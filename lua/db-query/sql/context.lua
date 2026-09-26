--[[
What the cursor is in, for completion, hover, and signature help.

`at` returns a `dbquery.CursorContext`: the word under the cursor, what kind of
name belongs there, the relations in scope, the function call and argument the
cursor is in, and the insert column list or values row it is in. The text may
be half typed.

Inside a `do` block or a function body, the body is read as its own sql, with
the function's parameters and declared variables in scope.
]]

local body = require("db-query.sql.body")
local lex = require("db-query.sql.lex")
local literals = require("db-query.sql.literal")
local relations = require("db-query.sql.relations")
local role = require("db-query.sql.role")
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

---@class dbquery.Call
---@field name string Dotted function name as written.
---@field argument integer Which argument the cursor is in, counting from 1.

---@class dbquery.InsertPosition : dbquery.InsertTarget
---@field list "columns"|"values"
---@field position integer Which entry of the list the cursor is in, counting from 1.

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

--- Token kinds that leave a value unwritten, so the next word opens one.
local UNWRITTEN = { operator = true, cast = true, [","] = true }

--- Kinds of token whose text is not code, so the cursor inside one is in no
--- statement.
local NOT_CODE = { comment = true, dollar = true, meta = true }

---@param kind dbquery.CursorKind
---@param word dbquery.Word
---@param prefix string
---@return dbquery.CursorContext
local function emptyContext(kind, word, prefix)
  return { kind = kind, word = word, prefix = prefix, scope = {}, inCase = false, afterCall = false, closed = false, opensValue = true }
end

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
  if relations.namesRelations(clause) then
    local at = index - 1
    while at >= 1 and not relations.startsFromItem(group.dialect, items[at]) and not lex.isWord(items[at], "on") do
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

--- Returns the context at `cursor`, which is outside every comment and dollar
--- quote, and inside no string but `literal`.
---@param document dbquery.Document
---@param cursor integer
---@param literal dbquery.Token|nil The string holding the cursor.
---@return dbquery.CursorContext
local function analyze(document, cursor, literal)
  local statement, word = statements.atCursor(document.dialect, document.tokens, cursor, literal)
  local root, cursorGroup, cursorIndex = syntax.groups(document.dialect, statement)
  local context = emptyContext("column", word, word.text:sub(1, cursor - word.first))

  local group, index = cursorGroup, cursorIndex
  -- True while walking up from a subquery through any parentheses around it.
  -- The first group above those parentheses decides whether the subquery sees
  -- that group's relations.
  local fromQuery = false
  local relationsVisible = true
  local previousGroup = nil
  while group do
    local groupRole = role.of(group)
    local items = group.items

    if group == cursorGroup then
      local previous = items[index - 1]
      context.previous = previous
      context.opensValue = opensValue(document.dialect, items, index)
      local caseDepth = 0
      for at = 1, index - 1 do
        if lex.isWord(items[at], "case") then
          caseDepth = caseDepth + 1
        elseif lex.isWord(items[at], "end") and caseDepth > 0 then
          caseDepth = caseDepth - 1
        end
      end
      context.inCase = caseDepth > 0
      context.afterCall = syntax.isGroup(previous) and role.of(previous.group).role == "call"
      if groupRole.role == "insert_columns" or groupRole.role == "values_row" then
        local list = groupRole.role == "insert_columns" and "columns" or "values"
        context.insert = vim.tbl_extend("force", groupRole.insert, { list = list, position = syntax.position(items, index) })
        context.kind = list == "columns" and "insert_columns" or "column"
      elseif groupRole.role == "columns_of" then
        context.kind, context.columnsOf = "columns_of", groupRole.table
      elseif groupRole.role == "statement" or groupRole.role == "query" or groupRole.role == "clause" then
        context.clause = syntax.clauses(group)[index]
        local altered = context.clause == "start" and alteredTable(items)
        local namesColumn = lex.isWord(previous, "column") or lex.isWord(previous, "drop") or lex.isWord(previous, "rename")
        if altered and namesColumn then
          context.kind, context.columnsOf = "columns_of", altered
        else
          context.kind = kindIn(group, index, context.clause)
        end
      end
      if previous and previous.kind == "." and lex.isIdentifier(items[index - 2]) then
        context.kind, context.qualifier = "qualified", (syntax.nameBefore(items, index - 2))
      end
      if literal then
        context.valueOf = literals.comparedName(items, index)
      end
    end

    if groupRole.role == "call" and not context.call then
      context.call = { name = (syntax.nameBefore(group.parent.items, group.index - 1)), argument = syntax.position(items, index) }
    end

    if literal and group == cursorGroup then
      context.castTo = literals.castName(items, index, context.call)
    end

    -- A value in a list, as in `status in ('a', 'b')`, is compared by the
    -- words written before the list.
    if literal and context.valueOf == nil and previousGroup == cursorGroup then
      context.valueOf = literals.comparedName(items, index)
    end

    if groupRole.role == "statement" or groupRole.role == "query" then
      local clauses, blocks = syntax.clauses(group)
      -- A CTE body, or a from item written without `lateral`, cannot read the
      -- relations of the query around it.
      local hidden = clauses[index] == "with"
        or (relations.namesRelations(clauses[index]) and not lex.isWord(items[index - 1], "lateral"))
      if fromQuery and hidden then
        relationsVisible = false
      end
      if relationsVisible then
        vim.list_extend(context.scope, relations.inBlock(group, clauses, blocks, blocks[index]))
        local insertTarget = relations.insertTarget(group)
        local inConflict = false
        for at = 1, index do
          inConflict = inConflict or clauses[at] == "conflict"
        end
        if insertTarget and inConflict and clauses[index] ~= "returning" then
          context.scope[#context.scope + 1] = { kind = "table", name = insertTarget.table, alias = "excluded" }
        end
        local ddlRelation = group == root and ddlTable(items)
        if ddlRelation then
          context.scope[#context.scope + 1] = ddlRelation
        end
      end
      vim.list_extend(context.scope, relations.ctes(items, clauses))
    end

    if groupRole.role == "query" then
      fromQuery = true
    elseif groupRole.role ~= "parens" then
      fromQuery = false
    end

    previousGroup, index = group, group.index
    group = group.parent
  end

  relations.resolveCtes(context.scope)
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
  local functionBody = body.at(document, cursor)
  if functionBody then
    local dialect = document.dialect
    local bodyDocument = { dialect = dialect, text = functionBody.text, tokens = lex.tokens(dialect, functionBody.text) }
    local context = M.at(bodyDocument, cursor - functionBody.offset)
    context.word.first = context.word.first + functionBody.offset
    context.word.last = context.word.last + functionBody.offset
    if context.kind ~= "none" then
      vim.list_extend(context.scope, functionBody.variables)
    end
    return context
  end
  -- Tokens never overlap, and one left open runs to the end of the text, so at
  -- most one string, comment, dollar quote, or client command holds the cursor.
  for _, token in ipairs(document.tokens) do
    local holdsCursor = token.first < cursor and (cursor <= token.last or token.open)
    if holdsCursor and token.kind == "string" then
      return analyze(document, cursor, token)
    end
    if holdsCursor and NOT_CODE[token.kind] then
      return emptyContext("none", { text = "", first = cursor, last = cursor - 1 }, "")
    end
  end
  return analyze(document, cursor, nil)
end

return M
