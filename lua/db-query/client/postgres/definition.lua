--[[
Reads the DDL of a postgres relation or function.
]]

local query = require("db-query.client.query")

local RELATION = [[
select json_build_object(
  'name', quote_ident(n.nspname) || '.' || quote_ident(c.relname),
  'kind', c.relkind,
  'persistence', c.relpersistence,
  'options', c.reloptions,
  'partitionKey', case when c.relkind = 'p' then pg_get_partkeydef(c.oid) end,
  'inherits', (select json_agg(i.inhparent::regclass::text order by i.inhseqno) from pg_inherits i where i.inhrelid = c.oid),
  'query', case when c.relkind in ('v', 'm') then pg_get_viewdef(c.oid, true) end,
  'server', (
    select quote_ident(s.srvname) from pg_foreign_table f join pg_foreign_server s on s.oid = f.ftserver
    where f.ftrelid = c.oid),
  'serverOptions', (select f.ftoptions from pg_foreign_table f where f.ftrelid = c.oid),
  'rowSecurity', c.relrowsecurity,
  'comment', obj_description(c.oid, 'pg_class'),
  'columns', (
    select json_agg(json_build_object(
      'name', quote_ident(a.attname), 'type', format_type(a.atttypid, a.atttypmod),
      'notnull', a.attnotnull, 'default', pg_get_expr(d.adbin, d.adrelid),
      'identity', a.attidentity, 'generated', a.attgenerated,
      'comment', col_description(c.oid, a.attnum)) order by a.attnum)
    from pg_attribute a
    left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
    where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped and a.attislocal),
  'constraints', (
    select json_agg(json_build_object('name', quote_ident(k.conname), 'definition', pg_get_constraintdef(k.oid, true))
      order by k.contype <> 'p', k.conname)
    from pg_constraint k
    where k.conrelid = c.oid and k.contype in ('p', 'u', 'f', 'c', 'x') and k.conislocal),
  'indexes', (
    select json_agg(pg_get_indexdef(i.indexrelid) order by i.indexrelid)
    from pg_index i
    where i.indrelid = c.oid and not exists (
      select 1 from pg_constraint k
      where k.conrelid = c.oid and k.conindid = i.indexrelid and k.contype in ('p', 'u', 'x'))),
  'triggers', (
    select json_agg(pg_get_triggerdef(g.oid, true) order by g.tgname)
    from pg_trigger g where g.tgrelid = c.oid and not g.tgisinternal))
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = :schema and c.relname = :name]]

local FUNCTIONS = [[
select json_build_object(
  'definition', pg_get_functiondef(p.oid), 'kind', p.prokind,
  'signature', quote_ident(n.nspname) || '.' || quote_ident(p.proname) || '(' || pg_get_function_identity_arguments(p.oid) || ')',
  'comment', obj_description(p.oid, 'pg_proc'))
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = :schema and p.proname = :name and p.prokind <> 'a'
order by p.oid]]

--- The word each kind of relation is created and commented on by.
local KINDS = {
  r = "TABLE",
  p = "TABLE",
  f = "FOREIGN TABLE",
  v = "VIEW",
  m = "MATERIALIZED VIEW",
}

--- Returns `settings`, written `key=value` as postgres keeps them, as the
--- `WITH` list a create statement takes, or an empty string when there are
--- none.
---@param settings string[]|nil
---@return string
local function withClause(settings)
  if not settings then
    return ""
  end
  return " WITH (" .. table.concat(settings, ", ") .. ")"
end

--- Reads `pg_get_functiondef` for each overload, with its comment. Postgres
--- keeps no definition of an aggregate.
---@param request dbquery.CatalogRequest
---@param functions dbquery.Function[]
---@param done fun(ddl: string|nil, err: string|nil)
local function functionDefinition(request, functions, done)
  local fn = functions[1]
  local statement = query.fill(FUNCTIONS, { schema = query.literal(fn.schema), name = query.literal(fn.name) })
  query.select(request, statement, function(overloads, err)
    if not overloads then
      return done(nil, err)
    end
    if #overloads == 0 then
      local aggregate = vim.iter(functions):any(function(overload)
        return overload.kind == "aggregate"
      end)
      return done(nil, aggregate and ("postgres keeps no definition of the aggregate " .. fn.name) or query.missing(fn))
    end
    local statements = {}
    for _, overload in ipairs(overloads) do
      table.insert(statements, overload.definition)
      if overload.comment then
        local objectKind = overload.kind == "p" and "PROCEDURE" or "FUNCTION"
        table.insert(statements, "COMMENT ON " .. objectKind .. " " .. overload.signature .. " IS " .. query.literal(overload.comment))
      end
    end
    done(query.script(statements))
  end)
end

--- Builds the relation's create statement from its columns and from the text
--- the server writes for its constraints, indexes, triggers, and view query,
--- then adds its comments. Postgres keeps no create statement to read.
---@param request dbquery.CatalogRequest
---@param relation dbquery.Relation
---@param done fun(ddl: string|nil, err: string|nil)
local function relationDefinition(request, relation, done)
  local statement = query.fill(RELATION, { schema = query.literal(relation.schema), name = query.literal(relation.name) })
  query.select(request, statement, function(rows, err)
    if not rows then
      return done(nil, err)
    end
    local row = rows[1]
    if not row then
      return done(nil, query.missing(relation))
    end

    local kind = KINDS[row.kind]
    local created
    if row.query then
      created = "CREATE " .. kind .. " " .. row.name .. withClause(row.options) .. " AS\n" .. row.query
    else
      local body = vim.tbl_map(function(column)
        local parts = { column.name, column.type }
        if column.notnull then
          table.insert(parts, "NOT NULL")
        end
        if column.identity == "a" then
          table.insert(parts, "GENERATED ALWAYS AS IDENTITY")
        elseif column.identity == "d" then
          table.insert(parts, "GENERATED BY DEFAULT AS IDENTITY")
        elseif column.generated == "s" or column.generated == "v" then
          table.insert(parts, "GENERATED ALWAYS AS (" .. column.default .. ")" .. (column.generated == "s" and " STORED" or " VIRTUAL"))
        elseif column.default then
          table.insert(parts, "DEFAULT " .. column.default)
        end
        return "    " .. table.concat(parts, " ")
      end, row.columns or {})
      for _, constraint in ipairs(row.constraints or {}) do
        table.insert(body, "    CONSTRAINT " .. constraint.name .. " " .. constraint.definition)
      end
      local parts = {
        "CREATE " .. (row.persistence == "u" and "UNLOGGED " or "") .. kind .. " " .. row.name .. " (\n",
        table.concat(body, ",\n"),
        "\n)",
      }
      if row.inherits then
        table.insert(parts, " INHERITS (" .. table.concat(row.inherits, ", ") .. ")")
      end
      if row.partitionKey then
        table.insert(parts, " PARTITION BY " .. row.partitionKey)
      end
      if row.server then
        local options = row.serverOptions and (" OPTIONS (" .. table.concat(vim.tbl_map(function(setting)
          local key, value = setting:match("^([^=]*)=(.*)$")
          return key .. " " .. query.literal(value)
        end, row.serverOptions), ", ") .. ")") or ""
        table.insert(parts, " SERVER " .. row.server .. options)
      end
      table.insert(parts, withClause(row.options))
      created = table.concat(parts)
    end

    local statements = { created }
    vim.list_extend(statements, row.indexes or {})
    vim.list_extend(statements, row.triggers or {})
    if row.rowSecurity then
      table.insert(statements, "ALTER TABLE " .. row.name .. " ENABLE ROW LEVEL SECURITY")
    end
    if row.comment then
      table.insert(statements, "COMMENT ON " .. kind .. " " .. row.name .. " IS " .. query.literal(row.comment))
    end
    for _, column in ipairs(row.columns or {}) do
      if column.comment then
        table.insert(statements, "COMMENT ON COLUMN " .. row.name .. "." .. column.name .. " IS " .. query.literal(column.comment))
      end
    end
    done(query.script(statements))
  end)
end

---@param request dbquery.CatalogRequest
---@param target dbquery.Target
---@param done fun(ddl: string|nil, err: string|nil)
return function(request, target, done)
  if target.kind == "functions" then
    return functionDefinition(request, target.functions, done)
  end
  relationDefinition(request, target.relation, done)
end
