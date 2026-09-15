--[[
Running statements through the duckdb cli.
]]

local duckdb = require("db-query.sql.dialect.duckdb")
local rows = require("db-query.catalog.rows")
local sql = require("db-query.sql")
local url = require("db-query.url")

local SEARCH_PATH = [[
select json_object('database', current_database(), 'setting', current_setting('search_path'))]]

-- duckdb_columns does not say which columns are generated, so each is looked
-- for in the table's own `create` statement, which duckdb writes as
-- `name TYPE GENERATED ALWAYS AS(`.
local RELATIONS = [[
select json_object(
  'database', c.database_name, 'schema', c.schema_name, 'name', c.table_name,
  'kind', case when v.view_name is null then 'table' else 'view' end,
  'comment', coalesce(t.comment, v.comment),
  'column', c.column_name, 'type', c.data_type, 'nullable', c.is_nullable,
  'default', c.column_default, 'columnComment', c.comment,
  'generated', coalesce(
    contains(t.sql, '(' || c.column_name || ' ' || c.data_type || ' GENERATED ALWAYS AS(')
      or contains(t.sql, ', ' || c.column_name || ' ' || c.data_type || ' GENERATED ALWAYS AS(')
      or contains(t.sql, '"' || replace(c.column_name, '"', '""') || '" ' || c.data_type || ' GENERATED ALWAYS AS('),
    false))
from duckdb_columns() c
left join duckdb_tables() t on t.table_oid = c.table_oid
left join duckdb_views() v on v.view_oid = c.table_oid
where not c.internal
order by c.database_name, c.schema_name, c.table_name, c.column_index]]

-- A pragma function is run by the PRAGMA statement, never called.
local FUNCTIONS = [[
select json_object(
  'database', database_name, 'schema', schema_name, 'name', function_name, 'kind', function_type,
  'names', parameters, 'types', parameter_types, 'varargs', varargs,
  'result', return_type, 'comment', description)
from duckdb_functions()
where function_type in ('scalar', 'aggregate', 'macro', 'table', 'table_macro')]]

local TYPES = [[
select json_object('database', database_name, 'schema', schema_name, 'name', type_name, 'enum', logical_type = 'ENUM')
from duckdb_types()
where not internal]]

local FUNCTION_KINDS = {
  scalar = { kind = "function", returnsSet = false },
  aggregate = { kind = "aggregate", returnsSet = false },
  macro = { kind = "macro", returnsSet = false },
  table = { kind = "function", returnsSet = true },
  table_macro = { kind = "macro", returnsSet = true },
}

---@param name string
---@return string
local function identifier(name)
  return '"' .. name:gsub('"', '""') .. '"'
end

---@param text string
---@return string
local function literal(text)
  return "'" .. text:gsub("'", "''") .. "'"
end

--- Returns where duckdb looks an unqualified name up: the `search_path`
--- setting, whose entries are `schema` or `database.schema`, or else the
--- current database's main schema, followed by the built-in schemas.
---@param row table
---@return dbquery.SchemaName[]
local function searchPath(row)
  local path = {}
  for entry in (row.setting or ""):gmatch("[^,]+") do
    local database, schema = vim.trim(entry):match("^([^.]+)%.(.+)$")
    table.insert(path, { database = database or row.database, schema = schema or vim.trim(entry) })
  end
  if #path == 0 then
    path[1] = { database = row.database, schema = "main" }
  end
  return vim.list_extend(path, {
    { database = "system", schema = "main" },
    { database = "system", schema = "pg_catalog" },
  })
end

---@param row table
---@return dbquery.Argument[]
local function arguments(row)
  local args = {}
  for index, name in ipairs(row.names) do
    local type = row.types[index]
    args[index] = { name = name, type = type ~= vim.NIL and type or nil, mode = "in", default = false }
  end
  if row.varargs then
    table.insert(args, { type = row.varargs, mode = "variadic", default = false })
  end
  return args
end

--- Calls `done` with each enum in `types` given its labels, which duckdb only
--- returns one type at a time.
---@param request dbquery.CatalogRequest
---@param types table[]
---@param done fun(types: dbquery.Type[]|nil, err: string|nil)
local function withLabels(request, types, done)
  local selects = {}
  for _, row in ipairs(types) do
    if row.enum then
      local name = table.concat({ identifier(row.database), identifier(row.schema), identifier(row.name) }, ".")
      table.insert(selects, string.format(
        "select json_object('database', %s, 'schema', %s, 'name', %s, 'labels', enum_range(null::%s))",
        literal(row.database),
        literal(row.schema),
        literal(row.name),
        name
      ))
    end
  end
  local function built(labels)
    return vim.tbl_map(function(row)
      return {
        database = row.database,
        schema = row.schema,
        name = row.name,
        labels = labels[row.database .. "." .. row.schema .. "." .. row.name],
      }
    end, types)
  end
  if #selects == 0 then
    return done(built({}))
  end
  rows.collect(request, { labels = table.concat(selects, "\nunion all\n") }, function(found, err)
    if not found then
      return done(nil, err)
    end
    local labels = {}
    for _, row in ipairs(found.labels) do
      labels[row.database .. "." .. row.schema .. "." .. row.name] = row.labels
    end
    done(built(labels))
  end)
end

---@param request dbquery.CatalogRequest
---@param done fun(catalog: dbquery.Catalog|nil, err: string|nil)
local function catalog(request, done)
  rows.collect(request, {
    searchPath = SEARCH_PATH,
    relations = RELATIONS,
    functions = FUNCTIONS,
    types = TYPES,
  }, function(found, err)
    if not found then
      return done(nil, err)
    end
    withLabels(request, found.types, function(types, labelErr)
      if not types then
        return done(nil, labelErr)
      end
      done({
        searchPath = searchPath(found.searchPath[1]),
        relations = rows.relations(found.relations, function(row)
          return {
            database = row.database,
            schema = row.schema,
            name = row.name,
            kind = row.kind,
            comment = row.comment,
            columns = {},
          }
        end, function(row)
          return {
            name = row.column,
            type = row.type,
            nullable = row.nullable,
            default = not row.generated and row.default or nil,
            generated = row.generated and "virtual" or nil,
            hidden = false,
            labels = rows.labels(row.type),
            comment = row.columnComment,
          }
        end),
        functions = vim.tbl_map(function(row)
          local kind = FUNCTION_KINDS[row.kind]
          return {
            database = row.database,
            schema = row.schema,
            name = row.name,
            kind = kind.kind,
            args = arguments(row),
            returnsSet = kind.returnsSet,
            result = row.result,
            comment = row.comment,
          }
        end, found.functions),
        types = types,
      })
    end)
  end)
end

---@type dbquery.Client
return {
  name = "duckdb",
  catalog = catalog,
  rows = { query = true, returning = true },
  delimited = "csv",
  embedded = true,
  dialect = duckdb,

  command = function(spec)
    local argv = { "duckdb" }
    if spec.format == "value" then
      vim.list_extend(argv, { "-noheader", "-list" })
    end
    local file = url.filePath(spec.connection)
    if file ~= "" then
      -- An in-memory database refuses -readonly, and has no file to protect.
      if spec.readonly then
        table.insert(argv, "-readonly")
      end
      table.insert(argv, file)
    end

    if not spec.path then
      vim.list_extend(argv, { "-c", spec.statement })
      return { argv = argv }
    end

    -- COPY takes a quoted path, so it reaches an output directory whose name
    -- has a space in it, but its argument has to be a select.
    if spec.format == "csv" and spec.kind == "query" then
      local copy = string.format(
        "COPY (\n%s\n) TO '%s' (FORMAT csv, HEADER)",
        sql.stripTerminator(duckdb, spec.statement),
        (spec.path:gsub("'", "''"))
      )
      vim.list_extend(argv, { "-c", copy })
      return { argv = argv }
    end

    -- .output takes any statement, but splits its argument on whitespace and
    -- reads quotes as part of the name, so it writes to `staging` instead.
    vim.list_extend(argv, {
      "-c",
      ".mode " .. (spec.format == "csv" and "csv" or "duckbox"),
      "-c",
      ".headers on",
      "-c",
      ".output " .. spec.staging,
      "-c",
      spec.statement,
    })
    return { argv = argv, staged = true }
  end,
}
