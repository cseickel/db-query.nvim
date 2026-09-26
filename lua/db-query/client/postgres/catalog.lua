--[[
Reads a postgres database's catalog.
]]

local query = require("db-query.client.query")

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
  'labels', (select json_agg(e.enumlabel order by e.enumsortorder) from pg_enum e where e.enumtypid = t.oid),
  'fields', (
    select json_agg(json_build_object(
      'name', a.attname,
      'type', format_type(a.atttypid, a.atttypmod),
      'typeOid', a.atttypid,
      'comment', col_description(c.oid, a.attnum)
    ) order by a.attnum)
    from pg_attribute a
    where a.attrelid = c.oid and c.relkind = 'c' and a.attnum > 0 and not a.attisdropped))
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
  for index, argType in ipairs(row.types or {}) do
    local name = row.names and row.names[index]
    local mode = MODES[row.modes and row.modes[index] or "i"]
    args[index] = { name = query.nonEmpty(name), type = argType, mode = mode, default = false }
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

    local labelsByTypeOid = {}
    for _, row in ipairs(results.types) do
      labelsByTypeOid[row.oid] = row.labels
    end

    done({
      searchPath = vim.tbl_map(function(row)
        return { schema = row.schema }
      end, results.searchPath),
      relations = query.relations(results.relations, function(row)
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
          generated = query.nonEmpty(row.identity) and "identity" or GENERATED[row.generated],
          hidden = false,
          labels = labelsByTypeOid[row.typeOid],
          comment = row.columnComment,
        }
      end),
      functions = vim.tbl_map(function(row)
        return {
          schema = row.schema,
          name = row.name,
          kind = FUNCTION_KINDS[row.kind],
          args = arguments(row),
          returnsSet = row.returnsSet,
          result = row.result,
          comment = row.comment,
        }
      end, results.functions),
      types = vim.tbl_map(function(row)
        return {
          schema = row.schema,
          name = row.name,
          labels = row.labels,
          columns = row.fields and vim.tbl_map(function(field)
            return {
              name = field.name,
              type = field.type,
              nullable = true,
              hidden = false,
              labels = labelsByTypeOid[field.typeOid],
              comment = field.comment,
            }
          end, row.fields),
        }
      end, results.types),
    })
  end)
end
