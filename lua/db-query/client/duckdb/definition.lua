--[[
The DDL of a duckdb relation or macro.

A relation's comes from the statements duckdb keeps for it and its indexes,
with its comments added, since those statements leave them out. A macro is
remade from its parameters and body, which duckdb keeps without the
parameters' defaults. Other functions are built in and have none.
]]

local duckdb = require("db-query.sql.dialect.duckdb")
local query = require("db-query.client.query")

local MACROS = [[
select json_object('type', function_type, 'parameters', parameters, 'definition', macro_definition)
from duckdb_functions()
where database_name = :database and schema_name = :schema and function_name = :name
  and function_type in ('macro', 'table_macro')
order by len(parameters), macro_definition]]

local RELATION = [[
select json_object('sql', sql, 'index', false) from duckdb_tables()
where database_name = :database and schema_name = :schema and table_name = :name
union all
select json_object('sql', sql, 'index', false) from duckdb_views()
where database_name = :database and schema_name = :schema and view_name = :name and not internal
union all
select json_object('sql', sql, 'index', true) from duckdb_indexes()
where database_name = :database and schema_name = :schema and table_name = :name and sql is not null]]

---@param named { database: string, schema: string, name: string }
---@return table<string, string>
local function literals(named)
  return {
    database = query.literal(named.database),
    schema = query.literal(named.schema),
    name = query.literal(named.name),
  }
end

---@param request dbquery.CatalogRequest
---@param fn dbquery.Function
---@param done fun(ddl: string|nil, err: string|nil)
local function macroDefinition(request, fn, done)
  query.select(request, query.fill(MACROS, literals(fn)), function(macros, err)
    if not macros then
      return done(nil, err)
    end
    if #macros == 0 then
      return done(nil, fn.name .. " is built into duckdb and has no definition")
    end
    local qualifiedName = query.qualified(duckdb, fn.database, fn.schema, fn.name)
    done(query.script(vim.tbl_map(function(macro)
      local parameters = vim.tbl_map(function(parameter)
        return query.qualified(duckdb, parameter)
      end, macro.parameters)
      return "CREATE MACRO " .. qualifiedName .. "(" .. table.concat(parameters, ", ") .. ") AS "
        .. (macro.type == "table_macro" and "TABLE " or "") .. macro.definition
    end, macros)))
  end)
end

---@param request dbquery.CatalogRequest
---@param relation dbquery.Relation
---@param done fun(ddl: string|nil, err: string|nil)
local function relationDefinition(request, relation, done)
  query.select(request, query.fill(RELATION, literals(relation)), function(rows, err)
    if not rows then
      return done(nil, err)
    end
    if #rows == 0 then
      return done(nil, query.missing(relation))
    end
    table.sort(rows, function(a, b)
      if a.index ~= b.index then
        return b.index
      end
      return a.sql < b.sql
    end)
    local statements = vim.tbl_map(function(row)
      return row.sql
    end, rows)
    local qualifiedName = query.qualified(duckdb, relation.database, relation.schema, relation.name)
    if relation.comment then
      local objectKind = relation.kind == "view" and "VIEW" or "TABLE"
      table.insert(statements, "COMMENT ON " .. objectKind .. " " .. qualifiedName .. " IS " .. query.literal(relation.comment))
    end
    for _, column in ipairs(relation.columns) do
      if column.comment then
        table.insert(statements, "COMMENT ON COLUMN " .. qualifiedName .. "." .. query.qualified(duckdb, column.name)
          .. " IS " .. query.literal(column.comment))
      end
    end
    done(query.script(statements))
  end)
end

---@param request dbquery.CatalogRequest
---@param target dbquery.Target
---@param done fun(ddl: string|nil, err: string|nil)
return function(request, target, done)
  if target.kind == "functions" then
    return macroDefinition(request, target.functions[1], done)
  end
  relationDefinition(request, target.relation, done)
end
