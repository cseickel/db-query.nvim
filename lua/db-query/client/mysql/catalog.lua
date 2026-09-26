--[[
Reads a mysql or mariadb database's catalog.
]]

local query = require("db-query.client.query")

local SEARCH_PATH = [[select json_object('schema', database())]]

local RELATIONS = [[
select json_object(
  'schema', t.table_schema, 'name', t.table_name, 'kind', t.table_type, 'comment', t.table_comment,
  'column', c.column_name, 'type', c.column_type, 'nullable', c.is_nullable, 'default', c.column_default,
  'extra', c.extra, 'columnComment', c.column_comment)
from information_schema.tables t
left join information_schema.columns c on c.table_schema = t.table_schema and c.table_name = t.table_name
order by t.table_schema, t.table_name, c.ordinal_position]]

-- Only stored routines are here. The server's own functions are in no table.
local ROUTINES = [[
select json_object(
  'schema', routine_schema, 'specific', specific_name, 'name', routine_name, 'kind', routine_type,
  'result', dtd_identifier, 'comment', routine_comment)
from information_schema.routines
where routine_type in ('FUNCTION', 'PROCEDURE')]]

-- Position 0 is a function's result, which `routines` already gives. A
-- function and a procedure may share a name, and with it a specific name.
local PARAMETERS = [[
select json_object(
  'schema', specific_schema, 'specific', specific_name, 'kind', routine_type, 'name', parameter_name,
  'mode', parameter_mode, 'type', dtd_identifier)
from information_schema.parameters
where ordinal_position > 0
order by specific_schema, specific_name, ordinal_position]]

---@param row table
---@return string
local function routineKey(row)
  return row.schema .. "." .. row.kind .. "." .. row.specific
end

---@param request dbquery.CatalogRequest
---@param done fun(catalog: dbquery.Catalog|nil, err: string|nil)
return function(request, done)
  query.collect(request, {
    searchPath = SEARCH_PATH,
    relations = RELATIONS,
    routines = ROUTINES,
    parameters = PARAMETERS,
  }, function(results, err)
    if not results then
      return done(nil, err)
    end

    local argsByRoutine = {}
    for _, row in ipairs(results.parameters) do
      local key = routineKey(row)
      argsByRoutine[key] = argsByRoutine[key] or {}
      table.insert(argsByRoutine[key], {
        name = row.name,
        type = row.type,
        mode = row.mode and row.mode:lower() or "in",
        default = false,
      })
    end

    local schema = results.searchPath[1].schema
    done({
      searchPath = schema and { { schema = schema } } or {},
      relations = query.relations(results.relations, function(row)
        local view = row.kind == "VIEW" or row.kind == "SYSTEM VIEW"
        return {
          schema = row.schema,
          name = row.name,
          kind = view and "view" or "table",
          -- mysql gives every view the comment VIEW.
          comment = row.comment ~= "VIEW" and query.nonEmpty(row.comment) or nil,
          columns = {},
        }
      end, function(row)
        if not row.column then
          return nil
        end
        -- Both servers mark a generated column `VIRTUAL GENERATED` or `STORED
        -- GENERATED` in `extra`. MySQL also writes `DEFAULT_GENERATED` for a
        -- column whose default is an expression.
        local extra = row.extra or ""
        local generated = extra:find("STORED GENERATED", 1, true) and "stored"
          or extra:find("VIRTUAL GENERATED", 1, true) and "virtual"
          or nil
        return {
          name = row.column,
          type = row.type,
          nullable = row.nullable == "YES",
          -- MariaDB writes a column without a default as the text NULL.
          default = row.default ~= "NULL" and row.default or nil,
          generated = generated,
          hidden = extra:find("INVISIBLE", 1, true) ~= nil,
          labels = query.labels(row.type),
          comment = query.nonEmpty(row.columnComment),
        }
      end),
      functions = vim.tbl_map(function(row)
        return {
          schema = row.schema,
          name = row.name,
          kind = row.kind:lower(),
          args = argsByRoutine[routineKey(row)] or {},
          returnsSet = false,
          result = row.result,
          comment = query.nonEmpty(row.comment),
        }
      end, results.routines),
      types = {},
    })
  end)
end
