--[[
Completion items for the cursor's context.

Every item replaces the whole word under the cursor and has a `sortText` that
puts the insert helpers first, then the columns in scope in their table's
order, aliases and CTEs, variables, tables, schemas, keywords, and functions.
An engine that sorts by it shows them in that order whatever their kind.
]]

local document = require("db-query.lsp.document")
local insert = require("db-query.lsp.insert")
local literal = require("db-query.lsp.literal")
local names = require("db-query.lsp.names")

local M = {}

local Kind = vim.lsp.protocol.CompletionItemKind

local GROUP = { column = 1, alias = 2, variable = 3, relation = 4, schema = 5, keyword = 6, ["function"] = 7 }

local RELATION_KIND = {
  table = Kind.Class,
  view = Kind.Interface,
  ["materialized view"] = Kind.Interface,
  ["foreign table"] = Kind.Class,
  ["virtual table"] = Kind.Class,
}

---@class dbquery.Completion
---@field opened dbquery.Opened
---@field context dbquery.CursorContext
---@field range lsp.Range
---@field snippets boolean The client accepts snippets.
---@field items lsp.CompletionItem[]
---@field seen table<string, true> Labels already offered, per group.
---@field quoting boolean The word under the cursor opens with a quote, so items are matched as they are written rather than by name.

---@param state dbquery.Completion
---@param item lsp.CompletionItem
---@param group integer
---@return lsp.CompletionItem
local function sorted(state, item, group)
  item.sortText = string.format("%d%05d", group, #state.items + 1)
  return item
end

--- Adds an item that writes `text`, once per label within its group.
---@param state dbquery.Completion
---@param group integer
---@param label string The name, unquoted.
---@param text string The name as sql writes it.
---@param kind integer
---@param detail string|nil
local function add(state, group, label, text, kind, detail)
  local key = group .. "\0" .. label
  if state.seen[key] then
    return
  end
  state.seen[key] = true
  state.items[#state.items + 1] = sorted(state, {
    label = label,
    kind = kind,
    detail = detail,
    filterText = state.quoting and text or label,
    textEdit = { range = state.range, newText = text },
  }, group)
end

--- Operators a subquery may be written after, as in `= any (select ...)`.
local COMPARES = { ["="] = true, ["<>"] = true, ["!="] = true, ["<"] = true, [">"] = true, ["<="] = true, [">="] = true }

--- Adds the dialect's keywords for `list`, in alphabetical order.
---@param state dbquery.Completion
---@param list string|nil A field of `dbquery.Keywords`, or a clause the dialect names no keywords for.
---@param skip table<string, true>|nil Words to leave out.
local function keywords(state, list, skip)
  local words = vim.tbl_keys(list and state.opened.document.dialect.keywords[list] or {})
  table.sort(words)
  for _, word in ipairs(words) do
    if not (skip and skip[word]) then
      add(state, GROUP.keyword, word, word, Kind.Keyword)
    end
  end
end

--- Adds the keywords that may be written where a value goes: the words that
--- open a value, or, once one is written, the words that may follow it and the
--- words that may follow the clause holding it.
---@param state dbquery.Completion
local function valueKeywords(state)
  local context = state.context
  local previous = context.previous
  if context.inCase then
    keywords(state, "case")
  end
  if not context.opensValue then
    keywords(state, "operator")
    -- A word that ends a value, such as the `desc` of an order by, is written
    -- once, so the clause no longer offers it or the words it stands among.
    local closes = state.opened.document.dialect.keywords.closes or {}
    local written = previous ~= nil and previous.kind == "word" and closes[previous.lower]
    keywords(state, context.clause, written and closes or nil)
    if context.afterCall then
      keywords(state, "call")
    end
    return
  end
  keywords(state, "expression")
  if previous ~= nil and previous.kind == "operator" and COMPARES[previous.text] then
    keywords(state, "quantifier")
  end
  if (previous ~= nil and previous.lower == "select") or (context.call ~= nil and context.call.argument == 1) then
    keywords(state, "projection")
  end
end

---@param state dbquery.Completion
---@param relation dbquery.ScopeRelation
local function scopeColumns(state, relation)
  local dialect = state.opened.document.dialect
  local owner = names.reference(dialect, relation)
  for _, offered in ipairs(names.columns(state.opened.catalog, dialect, relation)) do
    local type = offered.column and offered.column.type
    local detail = owner and (owner .. (type and (" " .. type) or "")) or type
    add(state, GROUP.column, offered.name, names.quote(dialect, offered.name), Kind.Field, detail)
  end
end

--- Returns the name a completion shows for `item` and the text it writes: its
--- name alone when an unqualified name finds it, and qualified by its schema
--- otherwise.
---@param state dbquery.Completion
---@param item { database: string|nil, schema: string|nil, name: string }
---@param qualify boolean
---@param spell fun(dialect: dbquery.Dialect, name: string): string
---@return string label
---@return string text
local function written(state, item, qualify, spell)
  local dialect = state.opened.document.dialect
  if qualify and item.schema then
    return item.schema .. "." .. item.name, names.quote(dialect, item.schema) .. "." .. spell(dialect, item.name)
  end
  return item.name, spell(dialect, item.name)
end

--- Adds the relations and functions of `relations` and `functions`, and the
--- insert statement for each table when the cursor is naming an insert's table.
---@param state dbquery.Completion
---@param relations dbquery.Relation[]
---@param functions dbquery.Function[]
---@param qualify boolean
local function relationItems(state, relations, functions, qualify)
  local dialect = state.opened.document.dialect
  local inserting = state.context.clause == "insert_target"
  for _, relation in ipairs(relations) do
    local label, text = written(state, relation, qualify, names.quote)
    add(state, GROUP.relation, label, text, RELATION_KIND[relation.kind] or Kind.Class, relation.kind)
    if inserting and state.snippets then
      local item = insert.statement(dialect, relation, label, text, state.range)
      if item then
        state.items[#state.items + 1] = sorted(state, item, GROUP.relation)
      end
    end
  end
  if inserting then
    return
  end
  for _, fn in ipairs(functions) do
    if fn.returnsSet or state.context.kind == "qualified" then
      local label, text = written(state, fn, qualify, names.callable)
      add(state, GROUP["function"], label, text, Kind.Function, fn.result)
    end
  end
end

--- Returns the items of `list` in a schema of the search path.
---@generic T : { database: string|nil, schema: string|nil }
---@param catalog dbquery.Catalog
---@param list T[]
---@return T[]
local function inSearchPath(catalog, list)
  return vim.iter(list):filter(function(item)
    return vim.iter(catalog.searchPath):any(function(path)
      return item.schema == path.schema and (path.database == nil or path.database == item.database)
    end)
  end):totable()
end

---@param state dbquery.Completion
local function relationsHere(state)
  local catalog = state.opened.catalog
  for _, relation in ipairs(state.context.scope) do
    if relation.kind == "cte" and relation.name then
      add(state, GROUP.alias, relation.name, relation.name, Kind.Struct, "cte")
    end
  end
  if not catalog then
    return
  end
  -- With no search path, as on a mariadb server without a default database,
  -- an unqualified name finds nothing, so every table is written qualified.
  local qualify = #catalog.searchPath == 0
  local relations = qualify and catalog.relations or inSearchPath(catalog, catalog.relations)
  local functions = qualify and {} or inSearchPath(catalog, catalog.functions)
  relationItems(state, relations, functions, qualify)
  local dialect = state.opened.document.dialect
  for _, relation in ipairs(catalog.relations) do
    if relation.schema then
      add(state, GROUP.schema, relation.schema, names.quote(dialect, relation.schema), Kind.Module, "schema")
    end
  end
end

---@param state dbquery.Completion
local function columnsHere(state)
  local dialect = state.opened.document.dialect
  for _, relation in ipairs(state.context.scope) do
    if relation.kind ~= "variable" and relation.kind ~= "trigger_row" then
      scopeColumns(state, relation)
    end
  end
  for _, relation in ipairs(state.context.scope) do
    local reference = names.reference(dialect, relation)
    if reference then
      local variable = relation.kind == "variable" or relation.kind == "trigger_row"
      add(state, variable and GROUP.variable or GROUP.alias, reference, names.quote(dialect, reference),
        variable and Kind.Variable or Kind.Struct, relation.name or relation.kind)
    end
  end
  local catalog = state.opened.catalog
  if catalog then
    local counts = {}
    -- sqlite's functions belong to no schema, so no search path holds them.
    local schemaless = vim.iter(catalog.functions):filter(function(fn)
      return fn.schema == nil
    end):totable()
    local functions = vim.iter(vim.list_extend(inSearchPath(catalog, catalog.functions), schemaless))
      :filter(function(fn)
        return fn.kind ~= "procedure"
      end)
      :totable()
    for _, fn in ipairs(functions) do
      counts[fn.name] = (counts[fn.name] or 0) + 1
    end
    for _, fn in ipairs(functions) do
      local detail = counts[fn.name] > 1 and (counts[fn.name] .. " overloads") or fn.result
      add(state, GROUP["function"], fn.name, names.callable(dialect, fn.name), Kind.Function, detail)
    end
  end
  valueKeywords(state)
end

---@param state dbquery.Completion
local function qualifiedHere(state)
  local context, catalog = state.context, state.opened.catalog
  local dialect = state.opened.document.dialect
  -- A schema being typed in from, as in `from reports.`, is read into scope
  -- as a table named `reports`, which offers no columns.
  for _, relation in ipairs(context.scope) do
    if names.refersTo(dialect, relation, context.qualifier) then
      scopeColumns(state, relation)
      if #state.items > 0 then
        return
      end
    end
  end
  if not catalog then
    return
  end
  local table = names.relation(catalog, dialect, context.qualifier)
  if table and context.clause ~= "insert_target" then
    scopeColumns(state, { kind = "table", name = context.qualifier })
  end
  local relations, functions = names.relationsIn(catalog, dialect, context.qualifier)
  relationItems(state, relations, functions, false)
end

--- Adds the values the string under the cursor may hold. A quote inside a
--- value is doubled, as sql escapes it, and a string left open is closed.
---@param state dbquery.Completion
local function literalValues(state)
  local quote = state.context.quote or "'"
  local closing = state.context.closed and "" or quote
  for _, label in ipairs(literal.labels(state.opened, state.context) or {}) do
    add(state, GROUP.column, label, label:gsub(vim.pesc(quote), quote .. quote) .. closing, Kind.EnumMember)
  end
end

---@param state dbquery.Completion
---@param table string
local function tableColumns(state, table)
  scopeColumns(state, { kind = "table", name = table })
end

---@param state dbquery.Completion
local function insertHere(state)
  local context, catalog = state.context, state.opened.catalog
  local dialect = state.opened.document.dialect
  local relation = catalog and names.relation(catalog, dialect, context.insert.table)
  if context.insert.list == "columns" then
    if relation then
      local all, columns = insert.columns(dialect, relation, context.insert.columns or {}, state.range, state.quoting)
      if all then
        state.items[#state.items + 1] = sorted(state, all, 0)
      end
      for _, item in ipairs(columns) do
        state.items[#state.items + 1] = sorted(state, item, GROUP.column)
      end
    end
    return
  end
  local text, cursor = state.opened.document.text, state.context.word.first
  local before = text:sub(1, cursor - 1):match("%(%s*$")
  local after = text:sub(state.context.word.last + 1):match("^%s*%)") or text:sub(state.context.word.last + 1):match("^%s*$")
  if state.snippets and context.insert.position == 1 and before and after then
    local item = insert.values(relation, context.insert.columns, dialect, state.range)
    if item then
      state.items[#state.items + 1] = sorted(state, item, 0)
    end
  end
  columnsHere(state)
end

--- Returns the completion items at `cursor` of `opened`.
---@param opened dbquery.Opened
---@param context dbquery.CursorContext
---@param cursor integer Byte offset the cursor stands before.
---@param snippets boolean
---@return lsp.CompletionItem[]
function M.items(opened, context, cursor, snippets)
  ---@type dbquery.Completion
  local state = {
    opened = opened,
    context = context,
    range = {
      start = document.position(opened.lines, context.word.first),
      ["end"] = document.position(opened.lines, math.max(cursor, context.word.last + 1)),
    },
    snippets = snippets,
    items = {},
    seen = {},
    quoting = opened.document.dialect.lex.identifiers[context.word.text:sub(1, 1)] ~= nil,
  }
  local kind = context.kind
  if context.insert and (kind == "insert_columns" or kind == "column") then
    insertHere(state)
  elseif kind == "relation" then
    relationsHere(state)
  elseif kind == "column" then
    columnsHere(state)
  elseif kind == "qualified" then
    qualifiedHere(state)
  elseif kind == "columns_of" then
    tableColumns(state, context.columnsOf)
  elseif kind == "literal" then
    literalValues(state)
  elseif kind == "keyword" then
    keywords(state, context.clause or "start")
  end
  return state.items
end

return M
