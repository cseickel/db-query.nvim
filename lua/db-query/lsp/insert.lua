--[[
Builds the completion items that write an insert's column list and values row.
]]

local items = require("db-query.lsp.items")
local names = require("db-query.lsp.names")

local M = {}

local Kind = vim.lsp.protocol.CompletionItemKind
local SNIPPET = vim.lsp.protocol.InsertTextFormat.Snippet

--- The value a column of each type starts as, keyed by the type's name in
--- lower case without its size, so `varchar(20)` is found as `varchar`.
---@type table<string, string>
local DEFAULT_VALUES_BY_TYPE = {}
for value, typeNames in pairs({
  ["0"] = [[
    smallint, integer, int, int2, int4, int8, bigint, tinyint, mediumint, hugeint, uhugeint,
    utinyint, usmallint, uinteger, ubigint, varint, bignum, big int, unsigned big int, serial, smallserial, bigserial, serial2,
    serial4, serial8, numeric, decimal, real, double, double precision, float, float4, float8,
    money
  ]],
  ["''"] = [[
    text, varchar, character varying, char, character, bpchar, nvarchar, nchar, string, citext,
    tinytext, mediumtext, longtext, clob, name, varying character, native character
  ]],
  ["false"] = "boolean, bool, logical",
  ["current_timestamp"] = [[
    timestamp, timestamptz, timestamp with time zone, timestamp without time zone, datetime,
    timestamp_s, timestamp_ms, timestamp_ns
  ]],
  ["current_date"] = "date",
  ["current_time"] = "time, timetz, time with time zone, time without time zone",
  ["'{}'"] = "json, jsonb",
}) do
  for _, typeName in ipairs(vim.split(vim.trim(typeNames), "%s*,%s*")) do
    DEFAULT_VALUES_BY_TYPE[typeName] = value
  end
end

--- Escapes text for use in a snippet.
---@param text string
---@return string
local function escaped(text)
  return (text:gsub("[\\$}]", "\\%0"))
end

--- Returns `list` joined by `, ` when it has fewer than 3 items, and one item
--- per indented line otherwise.
---@param list string[]
---@return string
local function listBody(list)
  if #list < 3 then
    return table.concat(list, ", ")
  end
  return "\n\t" .. table.concat(list, ",\n\t") .. "\n"
end

--- Returns the value a column starts as in an insert's values row. That is the
--- column's own default, NULL for a nullable column, and otherwise a value of
--- its type from DEFAULT_VALUES_BY_TYPE.
---@param dialect dbquery.Dialect
---@param column dbquery.Column
---@return string
local function defaultValue(dialect, column)
  if column.default or column.generated then
    return dialect.inserts.default and "DEFAULT" or column.default or "NULL"
  end
  if column.nullable then
    return "NULL"
  end
  if column.labels and column.labels[1] then
    return "'" .. column.labels[1]:gsub("'", "''") .. "'"
  end
  local columnType = column.type and column.type:lower()
  if not columnType then
    return "NULL"
  end
  if columnType:match("%[%d*%]$") then
    return dialect.inserts.array or "NULL"
  end
  -- postgres qualifies a type outside the search path, as in `extensions.citext`.
  local baseType = vim.trim((columnType:gsub("%b()", ""):gsub("%s+unsigned", ""):gsub("%s+zerofill", ""):gsub("%s+", " ")))
    :match("[^.]+$")
  if baseType == "uuid" then
    return dialect.inserts.uuid or "NULL"
  end
  return DEFAULT_VALUES_BY_TYPE[baseType] or "NULL"
end

--- Returns the inside of a values row, with one tabstop per column holding its
--- default value.
---@param dialect dbquery.Dialect
---@param columns dbquery.Column[]
---@return string
local function placeholders(dialect, columns)
  local tabstops = {}
  for index, column in ipairs(columns) do
    tabstops[index] = "${" .. index .. ":" .. escaped(defaultValue(dialect, column)) .. "}"
  end
  return listBody(tabstops)
end

---@param dialect dbquery.Dialect
---@param columns dbquery.Column[]
---@return string[]
local function quotedNames(dialect, columns)
  return vim.tbl_map(function(column)
    return names.quote(dialect, column.name)
  end, columns)
end

--- Returns the columns of `relation` an insert lists, which are those the
--- database neither fills itself nor hides.
---@param relation dbquery.Relation
---@return dbquery.Column[]
local function insertable(relation)
  return vim.iter(relation.columns):filter(function(column)
    return column.generated == nil and not column.hidden
  end):totable()
end

--- Adds the item that writes the table with its column list and values row,
--- such as `trades (id, qty) values (DEFAULT, 0)`.
---@param state dbquery.Completion
---@param relation dbquery.Relation
---@param label string The table's name as the completion shows it.
---@param quotedName string The table as the completion writes it.
function M.statement(state, relation, label, quotedName)
  local columns = insertable(relation)
  if #columns == 0 then
    return
  end
  local dialect = state.opened.document.dialect
  local newText = escaped(quotedName) .. " (" .. escaped(listBody(quotedNames(dialect, columns))) .. ") values ("
    .. placeholders(dialect, columns) .. ")$0"
  items.append(state, {
    label = label .. " (…) values (…)",
    kind = Kind.Snippet,
    filterText = label,
    insertTextFormat = SNIPPET,
    textEdit = { range = state.range, newText = newText },
    detail = #columns .. " columns",
  }, items.GROUP.relation)
end

--- Adds an item for each insertable column the insert's column list does not
--- hold yet, and, while the list is empty, an `all columns` item that writes
--- them all.
---@param state dbquery.Completion
---@param insertPosition dbquery.InsertPosition
function M.columnList(state, insertPosition)
  local catalog, dialect = state.opened.catalog, state.opened.document.dialect
  local relation = catalog and names.relation(catalog, dialect, insertPosition.table)
  if not relation then
    return
  end
  local listed = insertPosition.columns or {}
  local isListed = {}
  for _, name in ipairs(listed) do
    isListed[names.parts(dialect, name)[1].text:lower()] = true
  end
  local columnItems, unlisted = {}, {}
  for _, column in ipairs(insertable(relation)) do
    if not isListed[column.name:lower()] then
      unlisted[#unlisted + 1] = column
      local quoted = names.quote(dialect, column.name)
      columnItems[#columnItems + 1] = {
        label = column.name,
        kind = Kind.Field,
        detail = column.type,
        filterText = state.quoting and quoted or column.name,
        textEdit = { range = state.range, newText = quoted },
      }
    end
  end
  if #listed == 0 and #unlisted >= 2 then
    local unlistedNames = quotedNames(dialect, unlisted)
    local oneLine = table.concat(unlistedNames, ", ")
    items.append(state, {
      label = "all columns",
      kind = Kind.Snippet,
      detail = oneLine,
      filterText = "",
      insertTextFormat = state.snippets and SNIPPET or nil,
      textEdit = { range = state.range, newText = state.snippets and escaped(listBody(unlistedNames)) or oneLine },
    }, items.GROUP.insert)
  end
  for _, item in ipairs(columnItems) do
    items.append(state, item, items.GROUP.column)
  end
end

--- Adds the item that fills an empty values row for the listed columns, when
--- the insert has a column list and the client accepts snippets.
---@param state dbquery.Completion
---@param insertPosition dbquery.InsertPosition
function M.valuesRow(state, insertPosition)
  local catalog, dialect = state.opened.catalog, state.opened.document.dialect
  local relation = catalog and names.relation(catalog, dialect, insertPosition.table)
  local listed = insertPosition.columns or {}
  local text, word = state.opened.document.text, state.context.word
  local afterWord = text:sub(word.last + 1)
  local opensRow = text:sub(1, word.first - 1):match("%(%s*$") ~= nil
  local closesRow = afterWord:match("^%s*%)") ~= nil or afterWord:match("^%s*$") ~= nil
  if not (state.snippets and insertPosition.position == 1 and opensRow and closesRow and #listed > 0) then
    return
  end
  ---@type dbquery.Column[]
  local columns = vim.tbl_map(function(name)
    local columnName = names.parts(dialect, name)[1].text
    local column = relation and vim.iter(relation.columns):find(function(candidate)
      return candidate.name:lower() == columnName:lower()
    end)
    return column or { name = columnName, nullable = true, hidden = false }
  end, listed)
  items.append(state, {
    label = "(" .. table.concat(vim.tbl_map(function(column)
      return column.name
    end, columns), ", ") .. ")",
    kind = Kind.Snippet,
    filterText = "",
    insertTextFormat = SNIPPET,
    textEdit = { range = state.range, newText = placeholders(dialect, columns) .. "$0" },
    detail = "values for the listed columns",
  }, items.GROUP.insert)
end

return M
