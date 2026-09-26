--[[
The DDL of a mysql or mariadb relation or routine, from `show create`.
]]

local mysql = require("db-query.sql.dialect.mysql")
local query = require("db-query.client.query")

--- Where the statement sits among the tab-separated fields `show create`
--- prints, which a view's or routine's body may itself hold tabs in: the
--- fields before it and the fields after it.
---@type table<string, { before: integer, after: integer }>
local FIELDS = {
  table = { before = 1, after = 0 },
  view = { before = 1, after = 2 },
  ["function"] = { before = 2, after = 3 },
  procedure = { before = 2, after = 3 },
}

---@param request dbquery.CatalogRequest
---@param target dbquery.Target
---@param done fun(ddl: string|nil, err: string|nil)
return function(request, target, done)
  -- A function and a procedure may share a name, so each kind of routine
  -- among a function target's is shown.
  local objects = {}
  if target.kind == "functions" then
    local seenKinds = {}
    for _, fn in ipairs(target.functions) do
      if not seenKinds[fn.kind] then
        seenKinds[fn.kind] = true
        table.insert(objects, { kind = fn.kind, name = query.qualified(mysql, fn.schema, fn.name) })
      end
    end
  else
    local relation = target.relation
    objects[1] = {
      kind = relation.kind == "view" and "view" or "table",
      name = query.qualified(mysql, relation.schema, relation.name),
    }
  end

  local statements = vim.tbl_map(function(object)
    return "show create " .. object.kind .. " " .. object.name
  end, objects)
  query.all(request, statements, function(outputs, err)
    if not outputs then
      return done(nil, err)
    end
    local created = {}
    for index, object in ipairs(objects) do
      local fields = FIELDS[object.kind]
      local pattern = "^" .. string.rep("[^\t]*\t", fields.before) .. "(.*)" .. string.rep("\t[^\t]*", fields.after) .. "$"
      local statement = outputs[index]:gsub("\n$", ""):match(pattern)
      -- The server prints NULL for a routine whose body this user may not see.
      if not statement or statement == "NULL" then
        return done(nil, "the server shows this user no definition of " .. object.name)
      end
      created[index] = statement
    end
    done(query.script(created))
  end)
end
