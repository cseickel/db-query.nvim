--[[
The DDL of a duckdb relation or macro.

A relation's comes from the statements duckdb keeps for it and its indexes,
with its comments added, since those statements leave them out. A macro is
remade from its parameters and body, which duckdb keeps without the
parameters' defaults. Other functions are built in and have none.
]]

local ddl = require("db-query.client.definition")
local rows = require("db-query.catalog.rows")

---@param database string
---@param schema string
---@param name string
---@return string
local function qualified(database, schema, name)
  return table.concat({ ddl.identifier(database), ddl.identifier(schema), ddl.identifier(name) }, ".")
end

---@param request dbquery.CatalogRequest
---@param fn dbquery.Function
---@param done fun(ddl: string|nil, err: string|nil)
local function macros(request, fn, done)
  local statement = string.format([[
select json_object('type', function_type, 'parameters', parameters, 'definition', macro_definition)
from duckdb_functions()
where database_name = %s and schema_name = %s and function_name = %s and function_type in ('macro', 'table_macro')]],
    ddl.literal(fn.database), ddl.literal(fn.schema), ddl.literal(fn.name))
  request.query(statement, { timeout = request.timeout }, function(output, err)
    if not output then
      return done(nil, err)
    end
    local found = rows.decode(output)
    if #found == 0 then
      return done(nil, fn.name .. " is built into duckdb and has no definition")
    end
    local name = qualified(fn.database, fn.schema, fn.name)
    done(ddl.script(vim.tbl_map(function(row)
      return string.format(
        "CREATE MACRO %s(%s) AS %s%s",
        name,
        table.concat(vim.tbl_map(ddl.identifier, row.parameters), ", "),
        row.type == "table_macro" and "TABLE " or "",
        row.definition
      )
    end, found)))
  end)
end

---@param request dbquery.CatalogRequest
---@param relation dbquery.Relation
---@param done fun(ddl: string|nil, err: string|nil)
local function relationDefinition(request, relation, done)
  local where = string.format(
    "database_name = %s and schema_name = %s",
    ddl.literal(relation.database),
    ddl.literal(relation.schema)
  )
  local name = ddl.literal(relation.name)
  local statement = table.concat({
    string.format("select json_object('sql', sql, 'index', false) from duckdb_tables() where %s and table_name = %s", where, name),
    string.format("select json_object('sql', sql, 'index', false) from duckdb_views() where %s and view_name = %s and not internal", where, name),
    string.format("select json_object('sql', sql, 'index', true) from duckdb_indexes() where %s and table_name = %s and sql is not null", where, name),
  }, "\nunion all\n")
  request.query(statement, { timeout = request.timeout }, function(output, err)
    if not output then
      return done(nil, err)
    end
    local found = rows.decode(output)
    if #found == 0 then
      return done(nil, relation.name .. " is no longer in " .. relation.schema)
    end
    table.sort(found, function(a, b)
      if a.index ~= b.index then
        return b.index
      end
      return a.sql < b.sql
    end)
    local statements = vim.tbl_map(function(row)
      return row.sql
    end, found)
    local named = qualified(relation.database, relation.schema, relation.name)
    if relation.comment then
      local on = relation.kind == "view" and "VIEW" or "TABLE"
      table.insert(statements, string.format("COMMENT ON %s %s IS %s", on, named, ddl.literal(relation.comment)))
    end
    for _, column in ipairs(relation.columns) do
      if column.comment then
        table.insert(statements, string.format(
          "COMMENT ON COLUMN %s.%s IS %s", named, ddl.identifier(column.name), ddl.literal(column.comment)
        ))
      end
    end
    done(ddl.script(statements))
  end)
end

---@param request dbquery.CatalogRequest
---@param target dbquery.Target
---@param done fun(ddl: string|nil, err: string|nil)
return function(request, target, done)
  if target.kind == "functions" then
    return macros(request, target.functions[1], done)
  end
  relationDefinition(request, target.relation, done)
end
