--[[
Helpers for the queries a client runs to read its catalog, the DDL of an
object, and what depends on it.
]]

local lex = require("db-query.sql.lex")

local M = {}

--- An object that depends on another, as a client's `references` finds it.
---@class dbquery.Reference
---@field database string|nil
---@field schema string|nil
---@field name string
---@field routine boolean A function or procedure, rather than a relation.

--- Returns the catalog object `target` reads the DDL of: the first overload of
--- a function, and otherwise the relation, which for a column is its table.
---@param target dbquery.Target
---@return dbquery.Function|dbquery.Relation
function M.object(target)
  return target.kind == "functions" and target.functions[1] or target.relation
end

--- Returns `text` as a sql string literal.
---@param text string
---@return string
function M.literal(text)
  return "'" .. text:gsub("'", "''") .. "'"
end

--- Returns `parts` joined with `.`, each quoted the way `dialect` quotes a name.
---@param dialect dbquery.Dialect
---@param ... string
---@return string
function M.qualified(dialect, ...)
  local open, close = next(dialect.lex.identifiers)
  return table.concat(vim.tbl_map(function(part)
    return open .. part:gsub(vim.pesc(close), close .. close) .. close
  end, { ... }), ".")
end

--- Returns a `like` pattern, as a string literal, matching text that holds
--- `name` anywhere. The pattern escapes with `!`, so a statement using it adds
--- `escape '!'`.
---@param name string
---@return string
function M.containing(name)
  return M.literal("%" .. name:gsub("[!%%_]", "!%0") .. "%")
end

--- Returns `template` with each `:key` replaced by `values[key]`, which is
--- written as is, so a value must already be sql. A `::` cast is left alone.
--- Throws on a key `values` has no entry for.
---@param template string
---@param values table<string, string>
---@return string
function M.fill(template, values)
  return (template:gsub("(:?):([%a_][%w_]*)", function(cast, key)
    if cast ~= "" then
      return nil
    end
    return values[key] or error("no value for :" .. key)
  end))
end

--- Returns the message for an object that was in the catalog and is no longer
--- in the database.
---@param named { schema: string|nil, name: string }
---@return string
function M.missing(named)
  return named.name .. " is no longer in " .. (named.schema or "the database")
end

--- Returns the objects in `output`, one json object per line, with json null
--- read as nil inside an object. Throws when a line is not json.
---
--- A query that prints one object per row keeps every value short, where one
--- aggregated document can be cut off by a server limit such as mariadb's
--- `group_concat_max_len`.
---@param output string
---@return table[]
local function decode(output)
  local rows = {}
  for line in output:gmatch("[^\n]+") do
    if line:match("%S") then
      rows[#rows + 1] = vim.json.decode(line, { luanil = { object = true } })
    end
  end
  return rows
end

--- Runs every statement in `statements` at once, and calls `done` once: with
--- what each printed, under the same key, when all of them succeed, or with
--- the first error.
---@param request dbquery.CatalogRequest
---@param statements table<any, string>
---@param done fun(outputs: table<any, string>|nil, err: string|nil)
function M.all(request, statements, done)
  local outputs, pending, failed = {}, vim.tbl_count(statements), false
  if pending == 0 then
    return done(outputs)
  end
  for key, statement in pairs(statements) do
    request.query(statement, { timeout = request.timeout }, function(output, err)
      if failed then
        return
      end
      if not output then
        failed = true
        return done(nil, err)
      end
      outputs[key] = output
      pending = pending - 1
      if pending == 0 then
        done(outputs)
      end
    end)
  end
end

--- Runs `statement`, which prints one json object per row, and calls `done`
--- with the rows or with why it failed.
---@param request dbquery.CatalogRequest
---@param statement string
---@param done fun(rows: table[]|nil, err: string|nil)
function M.select(request, statement, done)
  request.query(statement, { timeout = request.timeout }, function(output, err)
    if not output then
      return done(nil, err)
    end
    done(decode(output))
  end)
end

--- Runs every statement in `statements` at once, each printing one json object
--- per row, and calls `done` once: with the rows of each, under the same key,
--- or with the first error.
---@param request dbquery.CatalogRequest
---@param statements table<string, string>
---@param done fun(rows: table<string, table[]>|nil, err: string|nil)
function M.collect(request, statements, done)
  M.all(request, statements, function(outputs, err)
    if not outputs then
      return done(nil, err)
    end
    done(vim.tbl_map(decode, outputs))
  end)
end

--- Returns the relations in `rows`, which hold one column each, grouped by
--- their `database`, `schema`, and `name` fields. Rows of one relation must be
--- adjacent and in column order. `column` returns nil for the row of a
--- relation with no columns.
---@param rows table[]
---@param relation fun(row: table): dbquery.Relation Builds the relation from its first row, columns left empty.
---@param column fun(row: table): dbquery.Column|nil
---@return dbquery.Relation[]
function M.relations(rows, relation, column)
  local relations, current, firstRow = {}, nil, nil
  for _, row in ipairs(rows) do
    if not (firstRow and firstRow.name == row.name and firstRow.schema == row.schema and firstRow.database == row.database) then
      firstRow, current = row, relation(row)
      relations[#relations + 1] = current
    end
    local built = column(row)
    if built then
      table.insert(current.columns, built)
    end
  end
  return relations
end

--- Returns the values of an `enum('a', 'b')` type, in any letter case, with
--- a doubled quote read as one. Returns nil for any other type.
---@param columnType string|nil
---@return string[]|nil
function M.labels(columnType)
  local list = columnType and columnType:match("^%s*[Ee][Nn][Uu][Mm]%s*%((.*)%)%s*$")
  if not list then
    return nil
  end
  local labels, index = {}, 1
  while true do
    local open = list:find("'", index, true)
    if not open then
      return labels
    end
    local value, at = {}, open + 1
    while at <= #list do
      local close = list:find("'", at, true)
      if not close then
        return labels
      end
      value[#value + 1] = list:sub(at, close - 1)
      if list:sub(close + 1, close + 1) ~= "'" then
        at = close + 1
        break
      end
      value[#value + 1] = "'"
      at = close + 2
    end
    labels[#labels + 1] = table.concat(value)
    index = at
  end
end

--- Returns `value`, or nil when it is empty.
---@param value string|nil
---@return string|nil
function M.nonEmpty(value)
  return value ~= "" and value or nil
end

--- Returns `statements` as one script, each ending in `;` and separated by a
--- blank line.
---@param statements string[]
---@return string
function M.script(statements)
  return table.concat(vim.tbl_map(function(statement)
    return (vim.trim(statement):gsub("%s*;$", "")) .. ";"
  end, statements), "\n\n") .. "\n"
end

--- Returns the references in `rows`, each once. A row holding `text` came from
--- a search of that text, and is kept only when the text names `name`.
---@param dialect dbquery.Dialect
---@param rows table[] Rows with `database`, `schema`, `name`, `routine`, and `text`. mysql writes `routine` as 1 or 0.
---@param name string
---@return dbquery.Reference[]
function M.references(dialect, rows, name)
  local references, seen = {}, {}
  for _, row in ipairs(rows) do
    local routine = row.routine == true or row.routine == 1
    local key = table.concat({ row.database or "", row.schema or "", row.name, tostring(routine) }, "\0")
    if not seen[key] and (row.text == nil or lex.mentions(dialect, row.text, name)) then
      seen[key] = true
      table.insert(references, { database = row.database, schema = row.schema, name = row.name, routine = routine })
    end
  end
  return references
end

return M
