--[[
What depends on a duckdb relation or macro: the tables whose foreign keys point
at it, and the views and macros whose text names it. duckdb keeps no record of
what a view or macro uses, so their text is searched.
]]

local ddl = require("db-query.client.definition")
local duckdb = require("db-query.sql.dialect.duckdb")
local rows = require("db-query.catalog.rows")

local FOREIGN_KEYS = [[
select json_object('database', database_name, 'schema', schema_name, 'name', table_name, 'routine', false)
from duckdb_constraints()
where constraint_type = 'FOREIGN KEY' and database_name = %s and schema_name = %s and referenced_table = %s
union all
]]

local SEARCHED = [[
select json_object('database', database_name, 'schema', schema_name, 'name', view_name, 'routine', false, 'text', sql)
from duckdb_views()
where not internal and sql ilike %s escape '!' and view_name <> %s
union all
select json_object('database', database_name, 'schema', schema_name, 'name', function_name, 'routine', true, 'text', macro_definition)
from duckdb_functions()
where function_type in ('macro', 'table_macro') and not internal and macro_definition ilike %s escape '!' and function_name <> %s]]

---@param request dbquery.CatalogRequest
---@param target dbquery.Target
---@param done fun(found: dbquery.Reference[]|nil, err: string|nil)
return function(request, target, done)
  local named = target.kind == "functions" and target.functions[1] or target.relation
  local name, pattern = ddl.literal(named.name), ddl.containing(named.name)
  local statement = string.format(SEARCHED, pattern, name, pattern, name)
  if target.kind ~= "functions" then
    statement = string.format(FOREIGN_KEYS, ddl.literal(named.database), ddl.literal(named.schema), name) .. statement
  end
  request.query(statement, { timeout = request.timeout }, function(output, err)
    if not output then
      return done(nil, err)
    end
    done(ddl.references(duckdb, rows.decode(output), named.name))
  end)
end
