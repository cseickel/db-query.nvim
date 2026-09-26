--[[
Completion items for the cursor's context.
]]

local columns = require("db-query.lsp.columns")
local describe = require("db-query.lsp.describe")
local document = require("db-query.lsp.document")
local insert = require("db-query.lsp.insert")
local items = require("db-query.lsp.items")
local literal = require("db-query.lsp.literal")
local names = require("db-query.lsp.names")

local M = {}

local Kind = vim.lsp.protocol.CompletionItemKind
local GROUP = items.GROUP

local RELATION_KIND = {
  table = Kind.Class,
  view = Kind.Interface,
  ["materialized view"] = Kind.Interface,
  ["foreign table"] = Kind.Class,
  ["virtual table"] = Kind.Class,
}

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
      items.add(state, GROUP.keyword, word, { label = word, kind = Kind.Keyword })
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
    local afterCloser = previous ~= nil and previous.kind == "word" and closes[previous.lower]
    keywords(state, context.clause, afterCloser and closes or nil)
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
  for _, column in ipairs(columns.of(state.opened.catalog, dialect, relation)) do
    local item = items.add(state, GROUP.column, names.quote(dialect, column.name), { label = column.name, kind = Kind.Field })
    if item and column.type then
      item.labelDetails = { description = column.type }
    end
  end
end

--- Returns the label and the text for `named`, both qualified by its schema
--- when `qualify` is set.
---@param state dbquery.Completion
---@param named { database: string|nil, schema: string|nil, name: string }
---@param qualify boolean
---@param writeName fun(dialect: dbquery.Dialect, name: string): string
---@return string label
---@return string text
local function labelAndText(state, named, qualify, writeName)
  local dialect = state.opened.document.dialect
  if qualify and named.schema then
    return named.schema .. "." .. named.name, names.quote(dialect, named.schema) .. "." .. writeName(dialect, named.name)
  end
  return named.name, writeName(dialect, named.name)
end

--- Returns what `fn` returns, one column per line, for an item's detail.
---@param dialect dbquery.Dialect
---@param fn dbquery.Function
---@return string|nil
local function returns(dialect, fn)
  local lines = describe.result(dialect, fn)
  return lines and table.concat(lines, "\n")
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
    local label, quotedName = labelAndText(state, relation, qualify, names.quote)
    items.add(state, GROUP.relation, quotedName, {
      label = label,
      kind = RELATION_KIND[relation.kind] or Kind.Class,
      detail = relation.kind,
    })
    if inserting and state.snippets then
      insert.statement(state, relation, label, quotedName)
    end
  end
  if inserting then
    return
  end
  for _, fn in ipairs(functions) do
    if fn.returnsSet or state.context.kind == "qualified" then
      local label, text = labelAndText(state, fn, qualify, names.callable)
      items.add(state, GROUP["function"], text, { label = label, kind = Kind.Function, detail = returns(dialect, fn) })
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
      items.add(state, GROUP.alias, relation.name, { label = relation.name, kind = Kind.Struct, detail = "cte" })
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
      items.add(state, GROUP.schema, names.quote(dialect, relation.schema), {
        label = relation.schema,
        kind = Kind.Module,
        detail = "schema",
      })
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
    local reference = columns.reference(dialect, relation)
    if reference then
      local variable = relation.kind == "variable" or relation.kind == "trigger_row"
      items.add(state, variable and GROUP.variable or GROUP.alias, names.quote(dialect, reference), {
        label = reference,
        kind = variable and Kind.Variable or Kind.Struct,
        detail = relation.name or relation.kind,
      })
    end
  end
  local catalog = state.opened.catalog
  if catalog then
    local overloadCounts = {}
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
      overloadCounts[fn.name] = (overloadCounts[fn.name] or 0) + 1
    end
    for _, fn in ipairs(functions) do
      local count = overloadCounts[fn.name]
      items.add(state, GROUP["function"], names.callable(dialect, fn.name), {
        label = fn.name,
        kind = Kind.Function,
        detail = count > 1 and (count .. " overloads") or returns(dialect, fn),
      })
    end
  end
  valueKeywords(state)
end

---@param state dbquery.Completion
local function qualifiedHere(state)
  local context, catalog = state.context, state.opened.catalog
  local dialect = state.opened.document.dialect
  -- In `from reports.`, scope holds `reports` as a table with no columns, so
  -- the loop falls through to the catalog lookup.
  for _, relation in ipairs(context.scope) do
    if columns.refersTo(dialect, relation, context.qualifier) then
      scopeColumns(state, relation)
      if #state.items > 0 then
        return
      end
    end
  end
  if not catalog then
    return
  end
  if context.clause ~= "insert_target" and names.relation(catalog, dialect, context.qualifier) then
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
    local text = label:gsub(vim.pesc(quote), quote .. quote) .. closing
    items.add(state, GROUP.column, text, { label = label, kind = Kind.EnumMember })
  end
end

--- Returns true when the request was made by typing a quote that closed what
--- an earlier quote opened. The quote that opens a string asks for the values
--- it may hold, and the quote that ends one asks for nothing.
---@param request dbquery.LspRequest
---@return boolean
local function closingQuote(request)
  local trigger, context = request.params.context, request.context
  if trigger == nil or trigger.triggerKind ~= vim.lsp.protocol.CompletionTriggerKind.TriggerCharacter then
    return false
  end
  local lex = request.opened.document.dialect.lex
  local character = trigger.triggerCharacter
  if lex.strings[character] ~= nil then
    return context.kind ~= "literal"
  end
  if lex.identifiers[character] ~= nil then
    -- A quoted name still being typed holds no closing quote yet.
    return #context.word.text > 1 and context.word.text:sub(-1) == character
  end
  return false
end

--- Returns the completion items for `request`.
---@param request dbquery.LspRequest
---@return lsp.CompletionItem[]
function M.items(request)
  if closingQuote(request) then
    return {}
  end
  local opened, context = request.opened, request.context
  ---@type dbquery.Completion
  local state = {
    opened = opened,
    context = context,
    range = {
      start = document.position(opened.lines, context.word.first),
      ["end"] = document.position(opened.lines, math.max(request.offset, context.word.last + 1)),
    },
    snippets = request.snippets,
    items = {},
    seen = {},
    quoting = opened.document.dialect.lex.identifiers[context.word.text:sub(1, 1)] ~= nil,
  }
  local kind = context.kind
  if context.insert and (kind == "insert_columns" or kind == "column") then
    if context.insert.list == "columns" then
      insert.columnList(state, context.insert)
    else
      insert.valuesRow(state, context.insert)
      columnsHere(state)
    end
  elseif kind == "relation" then
    relationsHere(state)
  elseif kind == "column" then
    columnsHere(state)
  elseif kind == "qualified" then
    qualifiedHere(state)
  elseif kind == "columns_of" then
    scopeColumns(state, { kind = "table", name = context.columnsOf })
  elseif kind == "literal" then
    literalValues(state)
  elseif kind == "keyword" then
    keywords(state, context.clause or "start")
  end
  return state.items
end

return M
