--[[
Running statements through psql.
]]

local psql = require("db-query.sql.dialect.psql")
local rows = require("db-query.catalog.rows")
local sql = require("db-query.sql")
local url = require("db-query.url")

--- Returns the statement psql runs to fill the results file: wrapped in COPY
--- for csv, and as written for text, where psql's own table is the output.
---@param spec dbquery.CommandSpec
---@return string
local function resultRows(spec)
  local body = sql.stripTerminator(psql, spec.statement)
  if spec.format ~= "csv" then
    return body
  end
  return "COPY (\n" .. body .. "\n) TO STDOUT WITH (FORMAT csv, HEADER)"
end

--- psql meta-command sending query results to `file`, or back to stdout when
--- `file` is nil. psql reads backslash escapes inside a single-quoted
--- meta-command argument, so both marks have to be escaped.
---@param file string|nil
---@return string
local function sendTo(file)
  if not file then
    return "\\o"
  end
  return "\\o '" .. file:gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
end

local SEARCH_PATH = [[
select json_build_object('schema', name)
from unnest(current_schemas(true)) with ordinality as path(name, position)
order by position]]

-- Partitions are left out, because a query names the table they belong to.
local RELATIONS = [[
select json_build_object(
  'schema', n.nspname, 'name', c.relname, 'kind', c.relkind,
  'comment', obj_description(c.oid, 'pg_class'),
  'column', a.attname, 'type', format_type(a.atttypid, a.atttypmod), 'typeOid', a.atttypid,
  'notnull', a.attnotnull, 'default', pg_get_expr(d.adbin, d.adrelid),
  'identity', a.attidentity, 'generated', a.attgenerated,
  'columnComment', col_description(c.oid, a.attnum))
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
left join pg_attrdef d on d.adrelid = c.oid and d.adnum = a.attnum
where c.relkind in ('r', 'p', 'v', 'm', 'f')
  and not c.relispartition
  and n.nspname !~ '^pg_(toast|temp)'
order by n.nspname, c.relname, a.attnum]]

local FUNCTIONS = [[
select json_build_object(
  'schema', n.nspname, 'name', p.proname, 'kind', p.prokind,
  'names', p.proargnames, 'modes', p.proargmodes,
  'types', (
    select json_agg(format_type(arg.type, null) order by arg.position)
    from unnest(coalesce(p.proallargtypes, p.proargtypes::oid[])) with ordinality as arg(type, position)
  ),
  'defaults', p.pronargdefaults, 'returnsSet', p.proretset,
  'result', case when p.prokind <> 'p' then pg_get_function_result(p.oid) end,
  'comment', obj_description(p.oid, 'pg_proc'))
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname !~ '^pg_(toast|temp)']]

-- Array types and the row type each table gets are left out. A composite type
-- made with `create type` stays.
local TYPES = [[
select json_build_object(
  'schema', n.nspname, 'name', t.typname, 'oid', t.oid,
  'labels', (select json_agg(e.enumlabel order by e.enumsortorder) from pg_enum e where e.enumtypid = t.oid))
from pg_type t
join pg_namespace n on n.oid = t.typnamespace
left join pg_class c on c.oid = t.typrelid
where t.typcategory <> 'A'
  and (t.typtype in ('b', 'd', 'e', 'r', 'm') or c.relkind = 'c')
  and n.nspname !~ '^pg_(toast|temp)']]

local RELATION_KINDS = {
  r = "table",
  p = "table",
  v = "view",
  m = "materialized view",
  f = "foreign table",
}
local FUNCTION_KINDS = { f = "function", p = "procedure", a = "aggregate", w = "window" }
local MODES = { i = "in", o = "out", b = "inout", v = "variadic", t = "table" }
local GENERATED = { s = "stored", v = "virtual" }

--- Returns a function's arguments. `pronargdefaults` counts the last
--- arguments a call passes that have a default, and out and table arguments
--- are never passed.
---@param row table
---@return dbquery.Argument[]
local function arguments(row)
  local args, passed = {}, {}
  for index, type in ipairs(row.types or {}) do
    local name = row.names and row.names[index]
    local mode = MODES[row.modes and row.modes[index] or "i"]
    args[index] = { name = rows.text(name), type = type, mode = mode, default = false }
    if mode ~= "out" and mode ~= "table" then
      passed[#passed + 1] = args[index]
    end
  end
  for index = #passed - row.defaults + 1, #passed do
    passed[index].default = true
  end
  return args
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

    local labels, types = {}, {}
    for index, row in ipairs(found.types) do
      types[index] = { schema = row.schema, name = row.name, labels = row.labels }
      labels[row.oid] = row.labels
    end

    local functions = {}
    for index, row in ipairs(found.functions) do
      functions[index] = {
        schema = row.schema,
        name = row.name,
        kind = FUNCTION_KINDS[row.kind],
        args = arguments(row),
        returnsSet = row.returnsSet,
        result = row.result,
        comment = row.comment,
      }
    end

    done({
      searchPath = vim.tbl_map(function(row)
        return { schema = row.schema }
      end, found.searchPath),
      relations = rows.relations(found.relations, function(row)
        return { schema = row.schema, name = row.name, kind = RELATION_KINDS[row.kind], comment = row.comment, columns = {} }
      end, function(row)
        if not row.column then
          return nil
        end
        return {
          name = row.column,
          type = row.type,
          nullable = not row.notnull,
          default = row.default,
          generated = rows.text(row.identity) and "identity" or GENERATED[row.generated],
          hidden = false,
          labels = labels[row.typeOid],
          comment = row.columnComment,
        }
      end),
      functions = functions,
      types = types,
    })
  end)
end

---@type dbquery.Client
return {
  name = "postgres",
  catalog = catalog,
  rows = { query = true, returning = true },
  delimited = "csv",
  dialect = psql,

  command = function(spec)
    local without, password = url.withoutPassword(spec.connection)
    local sessionFile = vim.fn.tempname() .. ".pid"
    local argv = { "psql", without, "-w", "--no-psqlrc", "-v", "ON_ERROR_STOP=1" }
    local script

    if spec.format == "value" then
      vim.list_extend(argv, { "-A", "-t", "-q", "-f", "-" })
      script = {
        sendTo(sessionFile),
        "SELECT pg_backend_pid();",
        sendTo(nil),
        spec.readonly and "BEGIN READ ONLY;" or "",
        spec.statement,
        ";",
        spec.readonly and "ROLLBACK;" or "",
        "",
      }
    elseif spec.path then
      vim.list_extend(argv, { "-f", "-" })
      script = {
        sendTo(sessionFile),
        "SELECT pg_backend_pid();",
        sendTo(spec.path),
        resultRows(spec),
        -- Separate semicolon in case the statement ends in a line comment.
        ";",
        sendTo(nil),
        "",
      }
    else
      -- -e echoes statements so row counts are labeled.
      vim.list_extend(argv, { "-e", "-f", "-" })
      script = {
        "\\set ECHO none",
        sendTo(sessionFile),
        "SELECT pg_backend_pid();",
        sendTo(nil),
        "\\set ECHO queries",
        "\\timing on\n",
        spec.statement,
        ";",
        "",
      }
    end

    return {
      argv = argv,
      env = password and { PGPASSWORD = password } or nil,
      sessionFile = sessionFile,
      stdin = table.concat(script, "\n"),
    }
  end,

  cancel = function(connection, pid)
    local without, password = url.withoutPassword(connection)
    return {
      argv = {
        "psql",
        without,
        "-w",
        "--no-psqlrc",
        "-q",
        "-c",
        "SELECT pg_cancel_backend(" .. pid .. ")",
      },
      env = password and { PGPASSWORD = password } or nil,
    }
  end,
}
