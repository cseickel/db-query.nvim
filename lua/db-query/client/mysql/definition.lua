--[[
The DDL of a mysql or mariadb relation or routine, from `show create`.
]]

local ddl = require("db-query.client.query")

---@param name string
---@return string
local function identifier(name)
  return "`" .. name:gsub("`", "``") .. "`"
end

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

--- Returns the statement in the output of `show create <kind>`, or nil when
--- the server printed NULL for a routine whose body this user may not see.
---@param kind string
---@param output string
---@return string|nil
local function created(kind, output)
  local fields = FIELDS[kind]
  local pattern = "^" .. string.rep("[^\t]*\t", fields.before) .. "(.*)" .. string.rep("\t[^\t]*", fields.after) .. "$"
  local statement = output:gsub("\n$", ""):match(pattern)
  return statement ~= "NULL" and statement or nil
end

--- Returns what to show: the relation, or each kind of routine among a
--- function target's, since a function and a procedure may share a name.
---@param target dbquery.Target
---@return { kind: string, name: string }[]
local function wanted(target)
  if target.kind ~= "functions" then
    local relation = target.relation
    return { {
      kind = relation.kind == "view" and "view" or "table",
      name = identifier(relation.schema) .. "." .. identifier(relation.name),
    } }
  end
  local found, seen = {}, {}
  for _, fn in ipairs(target.functions) do
    if not seen[fn.kind] then
      seen[fn.kind] = true
      table.insert(found, { kind = fn.kind, name = identifier(fn.schema) .. "." .. identifier(fn.name) })
    end
  end
  return found
end

---@param request dbquery.CatalogRequest
---@param target dbquery.Target
---@param done fun(ddl: string|nil, err: string|nil)
return function(request, target, done)
  local items = wanted(target)
  local statements, pending, failed = {}, #items, false
  for index, item in ipairs(items) do
    request.query("show create " .. item.kind .. " " .. item.name, { timeout = request.timeout }, function(output, err)
      if failed then
        return
      end
      local statement = output and created(item.kind, output)
      if not statement then
        failed = true
        return done(nil, err or ("the server shows this user no definition of " .. item.name))
      end
      statements[index] = statement
      pending = pending - 1
      if pending == 0 then
        done(ddl.script(statements))
      end
    end)
  end
end
