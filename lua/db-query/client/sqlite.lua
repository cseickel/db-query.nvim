--[[
Running statements through sqlite3.
]]

local rows = require("db-query.catalog.rows")
local url = require("db-query.url")

local SEARCH_PATH = [[
select json_object('schema', name, 'position', seq) from pragma_database_list]]

-- An fts table's shadow tables are its storage, which no query names.
-- pragma_table_xinfo fails the whole query on a view whose table was dropped,
-- which pragma_table_list reports as having no columns, so that view is left
-- out before the join reaches it.
local RELATIONS = [[
select json_object(
  'schema', t.schema, 'name', t.name, 'kind', t.type,
  'column', c.name, 'type', c.type, 'notnull', c."notnull", 'default', c.dflt_value, 'hidden', c.hidden)
from pragma_table_list as t
join pragma_table_xinfo(t.name, t.schema) as c
where t.type <> 'shadow' and t.ncol > 0 and t.name not like 'sqlite\_%' escape '\'
order by t.schema, t.name, c.cid]]

local FUNCTIONS = [[
select distinct json_object('name', name, 'kind', type, 'count', narg) from pragma_function_list]]

local RELATION_KINDS = { table = "table", view = "view", virtual = "virtual table" }
local FUNCTION_KINDS = { s = "function", a = "aggregate", w = "window" }
-- pragma_table_xinfo's `hidden`: 1 is a virtual table's hidden column, 2 a
-- virtual generated column, and 3 a stored one.
local GENERATED = { [2] = "virtual", [3] = "stored" }

--- Returns unnamed, untyped arguments for a function taking `count` of them,
--- where a negative count takes any number.
---@param count integer
---@return dbquery.Argument[]
local function arguments(count)
  if count < 0 then
    return { { mode = "variadic", default = false } }
  end
  local args = {}
  for index = 1, count do
    args[index] = { mode = "in", default = false }
  end
  return args
end

--- sqlite looks an unqualified name up in temp, then main, then the attached
--- databases in the order they were attached.
---@param found table[]
---@return dbquery.SchemaName[]
local function searchPath(found)
  table.sort(found, function(a, b)
    if (a.schema == "temp") ~= (b.schema == "temp") then
      return a.schema == "temp"
    end
    return a.position < b.position
  end)
  return vim.tbl_map(function(row)
    return { schema = row.schema }
  end, found)
end

---@param request dbquery.CatalogRequest
---@param done fun(catalog: dbquery.Catalog|nil, err: string|nil)
local function catalog(request, done)
  rows.collect(request, {
    searchPath = SEARCH_PATH,
    relations = RELATIONS,
    functions = FUNCTIONS,
  }, function(found, err)
    if not found then
      return done(nil, err)
    end
    done({
      searchPath = searchPath(found.searchPath),
      relations = rows.relations(found.relations, function(row)
        return { schema = row.schema, name = row.name, kind = RELATION_KINDS[row.kind], columns = {} }
      end, function(row)
        return {
          name = row.column,
          type = rows.text(row.type),
          nullable = row.notnull == 0,
          default = row.default,
          generated = GENERATED[row.hidden],
          hidden = row.hidden == 1,
        }
      end),
      functions = vim.tbl_map(function(row)
        return {
          name = row.name,
          kind = FUNCTION_KINDS[row.kind],
          args = arguments(row.count),
          returnsSet = false,
        }
      end, found.functions),
      types = {},
    })
  end)
end

---@type dbquery.Client
return {
  name = "sqlite",
  catalog = catalog,
  rows = { query = true, returning = true },
  delimited = "csv",
  embedded = true,
  dialect = require("db-query.sql.dialect.sqlite"),

  command = function(spec)
    local file = url.filePath(spec.connection)
    if spec.format == "value" then
      local argv = { "sqlite3", "-batch", "-noheader", "-list" }
      if spec.readonly then
        table.insert(argv, "-readonly")
      end
      return { argv = vim.list_extend(argv, { file, spec.statement }) }
    end
    if not spec.path then
      return { argv = { "sqlite3", file, spec.statement } }
    end

    return {
      argv = {
        "sqlite3",
        "-cmd",
        ".mode " .. (spec.format == "csv" and "csv" or "box"),
        "-cmd",
        ".headers on",
        -- .output splits on whitespace unless the name is in double quotes.
        "-cmd",
        '.output "' .. spec.path .. '"',
        file,
        spec.statement,
      },
    }
  end,
}
