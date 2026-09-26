--[[
What depends on a sqlite relation: the tables whose foreign keys point at it,
and the views, and tables with triggers, whose statements name it. sqlite keeps
no record of what a view or trigger uses, so their statements are searched.
Functions are built in, and nothing is recorded as depending on one.
]]

local ddl = require("db-query.client.query")
local rows = require("db-query.catalog.rows")
local sqlite = require("db-query.sql.dialect.sqlite")

local STATEMENT = [[
select json_object('schema', %s, 'name', m.name, 'routine', json('false'))
from %s.sqlite_master m
join pragma_foreign_key_list(m.name, %s) f
where m.type = 'table' and lower(f."table") = lower(%s) and m.name <> %s
union all
select json_object('schema', %s, 'name', m.tbl_name, 'routine', json('false'), 'text', m.sql)
from %s.sqlite_master m
where m.type in ('view', 'trigger') and m.tbl_name <> %s and m.sql like %s escape '!']]

---@param request dbquery.CatalogRequest
---@param target dbquery.Target
---@param done fun(found: dbquery.Reference[]|nil, err: string|nil)
return function(request, target, done)
  if target.kind == "functions" then
    return done({})
  end
  local relation = target.relation
  local schema, name = ddl.literal(relation.schema), ddl.literal(relation.name)
  local qualified = ddl.identifier(relation.schema)
  local statement = string.format(
    STATEMENT,
    schema, qualified, schema, name, name,
    schema, qualified, name, ddl.containing(relation.name)
  )
  request.query(statement, { timeout = request.timeout }, function(output, err)
    if not output then
      return done(nil, err)
    end
    done(ddl.references(sqlite, rows.decode(output), relation.name))
  end)
end
