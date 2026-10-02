--[[
Finds what depends on a mysql or mariadb relation or routine.
]]

local mysql = require("db-query.sql.dialect.mysql")
local query = require("db-query.client.query")

local FOREIGN_KEYS = [[
select json_object('schema', table_schema, 'name', table_name, 'routine', false)
from information_schema.key_column_usage
where referenced_table_schema = :schema and referenced_table_name = :name
  and not (table_schema = :schema and table_name = :name)
union all
]]

-- Neither server records what a view, routine, or trigger uses in a way both
-- can read, so their text is searched for the name.
local SEARCHED = [[
select json_object('schema', table_schema, 'name', table_name, 'routine', false, 'text', view_definition)
from information_schema.views
where view_definition like :pattern escape '!' and not (table_schema = :schema and table_name = :name)
union all
select json_object('schema', routine_schema, 'name', routine_name, 'routine', true, 'text', routine_definition)
from information_schema.routines
where routine_definition like :pattern escape '!' and not (routine_schema = :schema and routine_name = :name)
union all
select json_object('schema', event_object_schema, 'name', event_object_table, 'routine', false, 'text', action_statement)
from information_schema.triggers
where action_statement like :pattern escape '!' and not (event_object_schema = :schema and event_object_table = :name)]]

---@param request dbquery.CatalogRequest
---@param target dbquery.Target
---@param done fun(references: dbquery.Reference[]|nil, err: string|nil)
return function(request, target, done)
  local isFunction = target.kind == "functions"
  local named = query.object(target)
  local statement = query.fill((isFunction and "" or FOREIGN_KEYS) .. SEARCHED, {
    schema = query.literal(named.schema),
    name = query.literal(named.name),
    pattern = query.containing(named.name),
  })
  query.select(request, statement, function(rows, err)
    if not rows then
      return done(nil, err)
    end
    done(query.references(mysql, rows, named.name))
  end)
end
