--[[
The DDL of a sqlite relation: the statements that made it, its indexes, and its
triggers, which sqlite keeps as written. Functions are built in and have none.
]]

local ddl = require("db-query.client.definition")
local rows = require("db-query.catalog.rows")

---@param request dbquery.CatalogRequest
---@param target dbquery.Target
---@param done fun(ddl: string|nil, err: string|nil)
return function(request, target, done)
  if target.kind == "functions" then
    return done(nil, "sqlite's functions are built in and have no definition")
  end
  local relation = target.relation
  local statement = string.format([[
select json_object('sql', sql) from %s.sqlite_master
where tbl_name = %s and sql is not null
order by type not in ('table', 'view'), type = 'trigger', name]], ddl.identifier(relation.schema), ddl.literal(relation.name))
  request.query(statement, { timeout = request.timeout }, function(output, err)
    if not output then
      return done(nil, err)
    end
    local found = rows.decode(output)
    if #found == 0 then
      return done(nil, relation.name .. " is no longer in " .. relation.schema)
    end
    done(ddl.script(vim.tbl_map(function(row)
      return row.sql
    end, found)))
  end)
end
