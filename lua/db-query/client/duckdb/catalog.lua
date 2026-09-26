--[[
Reads a duckdb database's catalog.
]]

local duckdb = require("db-query.sql.dialect.duckdb")
local query = require("db-query.client.query")

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

local ENUM_LABELS = [[
select json_object('database', :database, 'schema', :schema, 'name', :name, 'labels', enum_range(cast(null as :type)))]]

local FUNCTION_KINDS = {
  scalar = { kind = "function", returnsSet = false },
  aggregate = { kind = "aggregate", returnsSet = false },
  macro = { kind = "macro", returnsSet = false },
  table = { kind = "function", returnsSet = true },
  table_macro = { kind = "macro", returnsSet = true },
}

---@param row table
---@return dbquery.Argument[]
local function arguments(row)
  local args = {}
  for index, name in ipairs(row.names) do
    local argType = row.types[index]
    args[index] = { name = name, type = argType ~= vim.NIL and argType or nil, mode = "in", default = false }
  end
  if row.varargs then
    table.insert(args, { type = row.varargs, mode = "variadic", default = false })
  end
  return args
end

--- Calls `done` with `types`, each enum given its labels, and with the labels
--- of each enum keyed by its database and name, which is how a column of that
--- enum names its type. duckdb reads the labels of one enum per call to
--- `enum_range`.
---@param request dbquery.CatalogRequest
---@param types table[]
---@param done fun(types: dbquery.Type[]|nil, labelsByColumnType: table<string, string[]>|nil, err: string|nil)
local function withLabels(request, types, done)
  local selects = {}
  for _, row in ipairs(types) do
    if row.enum then
      table.insert(selects, query.fill(ENUM_LABELS, {
        database = query.literal(row.database),
        schema = query.literal(row.schema),
        name = query.literal(row.name),
        type = query.qualified(duckdb, row.database, row.schema, row.name),
      }))
    end
  end

  ---@param labelsByType table<string, string[]>
  local function finish(labelsByType)
    local labelsByColumnType = {}
    local labeled = vim.tbl_map(function(row)
      local labels = labelsByType[row.database .. "." .. row.schema .. "." .. row.name]
      local columnType = row.database .. "." .. row.name
      if labels and not labelsByColumnType[columnType] then
        labelsByColumnType[columnType] = labels
      end
      return { database = row.database, schema = row.schema, name = row.name, labels = labels }
    end, types)
    done(labeled, labelsByColumnType)
  end

  if #selects == 0 then
    return finish({})
  end
  query.select(request, table.concat(selects, "\nunion all\n"), function(rows, err)
    if not rows then
      return done(nil, nil, err)
    end
    local labelsByType = {}
    for _, row in ipairs(rows) do
      labelsByType[row.database .. "." .. row.schema .. "." .. row.name] = row.labels
    end
    finish(labelsByType)
  end)
end

---@param request dbquery.CatalogRequest
---@param done fun(catalog: dbquery.Catalog|nil, err: string|nil)
return function(request, done)
  query.collect(request, {
    searchPath = SEARCH_PATH,
    relations = RELATIONS,
    functions = FUNCTIONS,
    types = TYPES,
  }, function(results, err)
    if not results then
      return done(nil, err)
    end
    withLabels(request, results.types, function(types, labelsByColumnType, labelErr)
      if not types then
        return done(nil, labelErr)
      end

      -- duckdb looks an unqualified name up in the `search_path` setting,
      -- whose entries are `schema` or `database.schema`, or else in the
      -- current database's main schema, and then in the built-in schemas.
      local setting = results.searchPath[1]
      local searchPath = {}
      for entry in (setting.setting or ""):gmatch("[^,]+") do
        local database, schema = vim.trim(entry):match("^([^.]+)%.(.+)$")
        table.insert(searchPath, { database = database or setting.database, schema = schema or vim.trim(entry) })
      end
      if #searchPath == 0 then
        searchPath[1] = { database = setting.database, schema = "main" }
      end
      vim.list_extend(searchPath, {
        { database = "system", schema = "main" },
        { database = "system", schema = "pg_catalog" },
      })

      done({
        searchPath = searchPath,
        relations = query.relations(results.relations, function(row)
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
            labels = query.labels(row.type) or labelsByColumnType[row.database .. "." .. row.type],
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
        end, results.functions),
        types = types,
      })
    end)
  end)
end
