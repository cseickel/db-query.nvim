--[[
What depends on a mysql or mariadb relation or routine: the tables whose
foreign keys point at it, and the views, routines, and tables with triggers
whose text names it. Neither server records what a view or routine uses in a
way both can read, so their text is searched.
]]

local ddl = require("db-query.client.definition")
local mysql = require("db-query.sql.dialect.mysql")
local rows = require("db-query.catalog.rows")

local FOREIGN_KEYS = [[
select json_object('schema', table_schema, 'name', table_name, 'routine', false)
from information_schema.key_column_usage
where referenced_table_schema = %s and referenced_table_name = %s
  and not (table_schema = %s and table_name = %s)
union all
]]

local SEARCHED = [[
select json_object('schema', table_schema, 'name', table_name, 'routine', false, 'text', view_definition)
from information_schema.views
where view_definition like %s escape '!' and not (table_schema = %s and table_name = %s)
union all
select json_object('schema', routine_schema, 'name', routine_name, 'routine', true, 'text', routine_definition)
from information_schema.routines
where routine_definition like %s escape '!' and not (routine_schema = %s and routine_name = %s)
union all
select json_object('schema', event_object_schema, 'name', event_object_table, 'routine', false, 'text', action_statement)
from information_schema.triggers
where action_statement like %s escape '!' and not (event_object_schema = %s and event_object_table = %s)]]

---@param request dbquery.CatalogRequest
---@param target dbquery.Target
---@param done fun(found: dbquery.Reference[]|nil, err: string|nil)
return function(request, target, done)
  local named = target.kind == "functions" and target.functions[1] or target.relation
  local schema, name, pattern = ddl.literal(named.schema), ddl.literal(named.name), ddl.containing(named.name)
  local statement = string.format(SEARCHED, pattern, schema, name, pattern, schema, name, pattern, schema, name)
  if target.kind ~= "functions" then
    statement = string.format(FOREIGN_KEYS, schema, name, schema, name) .. statement
  end
  request.query(statement, { timeout = request.timeout }, function(output, err)
    if not output then
      return done(nil, err)
    end
    done(ddl.references(mysql, rows.decode(output), named.name))
  end)
end
