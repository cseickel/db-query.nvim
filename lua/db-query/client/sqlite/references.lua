--[[
Finds what depends on a sqlite relation.
]]

local query = require("db-query.client.query")
local sqlite = require("db-query.sql.dialect.sqlite")

-- sqlite keeps no record of what a view or trigger uses, so their statements
-- are searched for the name.
local STATEMENT = [[
select json_object('schema', :schemaText, 'name', m.name, 'routine', json('false'))
from :schema.sqlite_master m
join pragma_foreign_key_list(m.name, :schemaText) f
where m.type = 'table' and lower(f."table") = lower(:name) and m.name <> :name
union all
select json_object('schema', :schemaText, 'name', m.tbl_name, 'routine', json('false'), 'text', m.sql)
from :schema.sqlite_master m
where m.type in ('view', 'trigger') and m.tbl_name <> :name and m.sql like :pattern escape '!']]

---@param request dbquery.CatalogRequest
---@param target dbquery.Target
---@param done fun(references: dbquery.Reference[]|nil, err: string|nil)
return function(request, target, done)
  if target.kind == "functions" then
    return done({})
  end
  local relation = target.relation
  local statement = query.fill(STATEMENT, {
    schema = query.qualified(sqlite, relation.schema),
    schemaText = query.literal(relation.schema),
    name = query.literal(relation.name),
    pattern = query.containing(relation.name),
  })
  query.select(request, statement, function(rows, err)
    if not rows then
      return done(nil, err)
    end
    done(query.references(sqlite, rows, relation.name))
  end)
end
