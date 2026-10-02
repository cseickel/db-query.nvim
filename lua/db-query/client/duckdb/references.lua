--[[
Finds what depends on a duckdb relation or macro.
]]

local duckdb = require("db-query.sql.dialect.duckdb")
local query = require("db-query.client.query")

local FOREIGN_KEYS = [[
select json_object('database', database_name, 'schema', schema_name, 'name', table_name, 'routine', false)
from duckdb_constraints()
where constraint_type = 'FOREIGN KEY' and database_name = :database and schema_name = :schema and referenced_table = :name
union all
]]

-- duckdb keeps no record of what a view or macro uses, so their text is
-- searched for the name.
local SEARCHED = [[
select json_object('database', database_name, 'schema', schema_name, 'name', view_name, 'routine', false, 'text', sql)
from duckdb_views()
where not internal and sql ilike :pattern escape '!'
  and not (database_name = :database and schema_name = :schema and view_name = :name)
union all
select json_object('database', database_name, 'schema', schema_name, 'name', function_name, 'routine', true, 'text', macro_definition)
from duckdb_functions()
where function_type in ('macro', 'table_macro') and not internal and macro_definition ilike :pattern escape '!'
  and not (database_name = :database and schema_name = :schema and function_name = :name)]]

---@param request dbquery.CatalogRequest
---@param target dbquery.Target
---@param done fun(references: dbquery.Reference[]|nil, err: string|nil)
return function(request, target, done)
  local isFunction = target.kind == "functions"
  local named = query.object(target)
  local statement = query.fill((isFunction and "" or FOREIGN_KEYS) .. SEARCHED, {
    database = query.literal(named.database),
    schema = query.literal(named.schema),
    name = query.literal(named.name),
    pattern = query.containing(named.name),
  })
  query.select(request, statement, function(rows, err)
    if not rows then
      return done(nil, err)
    end
    done(query.references(duckdb, rows, named.name))
  end)
end
