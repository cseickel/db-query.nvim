--[[
The DDL of a sqlite relation: the statements that made it, its indexes, and its
triggers, which sqlite keeps as written. Functions are built in and have none.
]]

local query = require("db-query.client.query")
local sqlite = require("db-query.sql.dialect.sqlite")

local STATEMENTS = [[
select json_object('sql', sql) from :schema.sqlite_master
where tbl_name = :name and sql is not null
order by type not in ('table', 'view'), type = 'trigger', name]]

---@param request dbquery.CatalogRequest
---@param target dbquery.Target
---@param done fun(ddl: string|nil, err: string|nil)
return function(request, target, done)
  if target.kind == "functions" then
    return done(nil, "sqlite's functions are built in and have no definition")
  end
  local relation = target.relation
  local statement = query.fill(STATEMENTS, {
    schema = query.qualified(sqlite, relation.schema),
    name = query.literal(relation.name),
  })
  query.select(request, statement, function(rows, err)
    if not rows then
      return done(nil, err)
    end
    if #rows == 0 then
      return done(nil, query.missing(relation))
    end
    done(query.script(vim.tbl_map(function(row)
      return row.sql
    end, rows)))
  end)
end
