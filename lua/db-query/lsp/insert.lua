--[[
Completion items that write an insert's column list and values row.
]]

local names = require("db-query.lsp.names")

local M = {}

local Kind = vim.lsp.protocol.CompletionItemKind
local SNIPPET = vim.lsp.protocol.InsertTextFormat.Snippet

--- The value a column of each type starts as, keyed by the type's name in
--- lower case without its size, so `varchar(20)` is found as `varchar`.
---@type table<string, string>
local DEFAULT_VALUES_BY_TYPE = {}
for default_value, types in pairs({
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
  for _, type in ipairs(vim.split(vim.trim(types), "%s*,%s*")) do
    DEFAULT_VALUES_BY_TYPE[type] = default_value
  end
end

--- Escapes text for use in a snippet.
---@param text string
---@return string
local function escaped(text)
  return (text:gsub("[\\$}]", "\\%0"))
end

--- Formats a list of columns or values.
---@param items string[]
---@return string
local function listBody(items)
  if #items < 3 then
    return table.concat(items, ", ")
  end
  return "\n\t" .. table.concat(items, ",\n\t") .. "\n"
end

--- Returns the the default value for a column in an insert's values row.
--- It uses the columns own default if one exists, or the type's default as
--- we define it.
---@param inserts dbquery.InsertValues
---@param column dbquery.Column
---@return string
local function typeValue(inserts, column)
  if column.labels and column.labels[1] then
    return "'" .. column.labels[1]:gsub("'", "''") .. "'"
  end
  local type = column.type and column.type:lower()
  if not type then
    return "NULL"
  end
  if type:match("%[%d*%]$") then
    return inserts.array or "NULL"
  end
  -- postgres qualifies a type outside the search path, as in `extensions.citext`.
  local name = vim.trim((type:gsub("%b()", ""):gsub("%s+unsigned", ""):gsub("%s+zerofill", ""):gsub("%s+", " ")))
    :match("[^.]+$")
  if name == "uuid" then
    return inserts.uuid or "NULL"
  end
  return DEFAULT_VALUES_BY_TYPE[name] or "NULL"
end

--- Returns the value a values row starts with for `column`: its default, which
--- a generated or identity column always takes, NULL for a nullable column
--- without one, and otherwise the value for its type. A column the catalog
--- does not know gets NULL.
---@param inserts dbquery.InsertValues
---@param column dbquery.Column|nil
---@return string
local function startingValue(inserts, column)
  if not column then
    return "NULL"
  end
  if column.default or column.generated then
    return inserts.default and "DEFAULT" or column.default or "NULL"
  end
  if column.nullable then
    return "NULL"
  end
  return typeValue(inserts, column)
end

--- Returns the inside of a values row for `columns`, one placeholder per value.
---@param inserts dbquery.InsertValues
---@param columns dbquery.OfferedColumn[]
---@return string
local function placeholders(inserts, columns)
  local parts = {}
  for index, offered in ipairs(columns) do
    parts[index] = "${" .. index .. ":" .. escaped(startingValue(inserts, offered.column)) .. "}"
  end
  return listBody(parts)
end

---@param dialect dbquery.Dialect
---@param columns dbquery.Column[]
---@return string[]
local function quotedNames(dialect, columns)
  return vim.tbl_map(function(column)
    return names.quote(dialect, column.name)
  end, columns)
end

--- Returns the item that writes `written`, the table being completed, with its
--- column list and a values row: `trades (id, qty) values (DEFAULT, 0)`.
---@param dialect dbquery.Dialect
---@param relation dbquery.Relation
---@param label string The table's name as the completion shows it.
---@param written string The table as the completion writes it.
---@param range lsp.Range
---@return lsp.CompletionItem|nil
function M.statement(dialect, relation, label, written, range)
  local columns = names.insertable(relation)
  if #columns == 0 then
    return nil
  end
  local offered = vim.tbl_map(function(column)
    return { name = column.name, column = column }
  end, columns)
  local text = escaped(written) .. " (" .. escaped(listBody(quotedNames(dialect, columns))) .. ") values ("
    .. placeholders(dialect.inserts, offered) .. ")$0"
  return {
    label = label .. " (…) values (…)",
    kind = Kind.Snippet,
    filterText = label,
    insertTextFormat = SNIPPET,
    textEdit = { range = range, newText = text },
    detail = #columns .. " columns",
  }
end

--- Returns the items for an insert's column list: while the list is empty, one
--- item writing every insertable column, and an item for each insertable
--- column not listed yet, in the table's order. The item writing every column
--- is a snippet.
---@param dialect dbquery.Dialect
---@param relation dbquery.Relation
---@param listed string[] The columns already written.
---@param range lsp.Range
---@param quoting boolean The word under the cursor opens with a quote.
---@return lsp.CompletionItem|nil all
---@return lsp.CompletionItem[] columns
function M.columns(dialect, relation, listed, range, quoting)
  local taken = {}
  for _, name in ipairs(listed) do
    taken[names.parts(dialect, name)[1].text:lower()] = true
  end
  local items, remaining = {}, {}
  for _, column in ipairs(names.insertable(relation)) do
    if not taken[column.name:lower()] then
      remaining[#remaining + 1] = column
      local text = names.quote(dialect, column.name)
      items[#items + 1] = {
        label = column.name,
        kind = Kind.Field,
        detail = column.type,
        filterText = quoting and text or column.name,
        textEdit = { range = range, newText = text },
      }
    end
  end
  if #listed > 0 or #remaining < 2 then
    return nil, items
  end
  local written = quotedNames(dialect, remaining)
  return {
    label = "all columns",
    kind = Kind.Snippet,
    detail = table.concat(written, ", "),
    filterText = "",
    insertTextFormat = SNIPPET,
    textEdit = { range = range, newText = escaped(listBody(written)) },
  }, items
end

--- Returns the item that fills an empty values row for the columns `listed`,
--- or nil when no column list is written, since values without one would
--- land in whichever columns come first.
---@param relation dbquery.Relation|nil
---@param listed string[]|nil
---@param dialect dbquery.Dialect
---@param range lsp.Range
---@return lsp.CompletionItem|nil
function M.values(relation, listed, dialect, range)
  if not listed or #listed == 0 then
    return nil
  end
  ---@type dbquery.OfferedColumn[]
  local columns = vim.tbl_map(function(name)
    local text = names.parts(dialect, name)[1].text
    local found = relation and vim.iter(relation.columns):find(function(column)
      return column.name:lower() == text:lower()
    end)
    return { name = text, column = found }
  end, listed)
  return {
    label = "(" .. table.concat(vim.tbl_map(function(column)
      return column.name
    end, columns), ", ") .. ")",
    kind = Kind.Snippet,
    filterText = "",
    insertTextFormat = SNIPPET,
    textEdit = { range = range, newText = placeholders(dialect.inserts, columns) .. "$0" },
    detail = "values for the listed columns",
  }
end

return M
