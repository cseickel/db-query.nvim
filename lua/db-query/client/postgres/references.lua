--[[
What depends on a postgres relation or function.

`pg_depend` records what views, sql-standard function bodies, column
defaults, and constraints use, and foreign keys and triggers name what they
point at. A plpgsql body records nothing, so function bodies are also searched
for the name.
]]

local ddl = require("db-query.client.query")
local psql = require("db-query.sql.dialect.psql")
local rows = require("db-query.catalog.rows")

-- A function whose body the server compiles holds no text to search.
local BODIES = [[
select json_build_object('schema', n.nspname, 'name', p.proname, 'routine', true, 'text', p.prosrc)::text
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
join pg_language l on l.oid = p.prolang
where l.lanname not in ('c', 'internal') and p.prosrc ilike %s escape '!'
  and p.oid not in (select oid from target)
  and n.nspname !~ '^pg_' and n.nspname <> 'information_schema']]

local VIEWS = [[
select json_build_object('schema', n.nspname, 'name', c.relname, 'routine', false)::text
from pg_depend d
join pg_rewrite r on r.oid = d.objid
join pg_class c on c.oid = r.ev_class
join pg_namespace n on n.oid = c.relnamespace
where d.classid = 'pg_rewrite'::regclass and d.refclassid = %s::regclass
  and d.refobjid in (select oid from target) and c.oid not in (select oid from target)]]

local FUNCTIONS = [[
select json_build_object('schema', n.nspname, 'name', p.proname, 'routine', true)::text
from pg_depend d
join pg_proc p on p.oid = d.objid
join pg_namespace n on n.oid = p.pronamespace
where d.classid = 'pg_proc'::regclass and d.refclassid = %s::regclass
  and d.refobjid in (select oid from target) and p.oid not in (select oid from target)]]

local RELATION = [[
with target as (
  select c.oid from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = %s and c.relname = %s)
%s
union
%s
union
select json_build_object('schema', n.nspname, 'name', c.relname, 'routine', false)::text
from pg_constraint k
join pg_class c on c.oid = k.conrelid
join pg_namespace n on n.oid = c.relnamespace
where k.contype = 'f' and k.confrelid in (select oid from target) and k.conrelid not in (select oid from target)
union
%s]]

local FUNCTION = [[
with target as (
  select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = %s and p.proname = %s)
%s
union
%s
union
select json_build_object('schema', n.nspname, 'name', c.relname, 'routine', false)::text
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
where t.tgfoid in (select oid from target) and not t.tgisinternal
union
select json_build_object('schema', n.nspname, 'name', c.relname, 'routine', false)::text
from pg_depend d
join pg_attrdef a on a.oid = d.objid
join pg_class c on c.oid = a.adrelid
join pg_namespace n on n.oid = c.relnamespace
where d.classid = 'pg_attrdef'::regclass and d.refclassid = 'pg_proc'::regclass and d.refobjid in (select oid from target)
union
select json_build_object('schema', n.nspname, 'name', c.relname, 'routine', false)::text
from pg_depend d
join pg_constraint k on k.oid = d.objid
join pg_class c on c.oid = k.conrelid
join pg_namespace n on n.oid = c.relnamespace
where d.classid = 'pg_constraint'::regclass and d.refclassid = 'pg_proc'::regclass and d.refobjid in (select oid from target)
union
%s]]

---@param request dbquery.CatalogRequest
---@param target dbquery.Target
---@param done fun(found: dbquery.Reference[]|nil, err: string|nil)
return function(request, target, done)
  local named = target.kind == "functions" and target.functions[1] or target.relation
  local class = target.kind == "functions" and "'pg_proc'" or "'pg_class'"
  local statement = string.format(
    target.kind == "functions" and FUNCTION or RELATION,
    ddl.literal(named.schema),
    ddl.literal(named.name),
    string.format(VIEWS, class),
    string.format(FUNCTIONS, class),
    string.format(BODIES, ddl.containing(named.name))
  )
  request.query(statement, { timeout = request.timeout }, function(output, err)
    if not output then
      return done(nil, err)
    end
    done(ddl.references(psql, rows.decode(output), named.name))
  end)
end
