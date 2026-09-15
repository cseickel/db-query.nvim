--[[
The catalog every client reads its database into, and the check that a catalog
has that shape.

Names are qualified the way the sql writes them: `schema` is the qualifier just
left of a name, and `database` is the one left of `schema`, for a database
such as duckdb that has one.
]]

local M = {}

---@alias dbquery.RelationKind "table"|"view"|"materialized view"|"foreign table"|"virtual table"
---@alias dbquery.FunctionKind "function"|"procedure"|"aggregate"|"window"|"macro"
---@alias dbquery.ArgumentMode "in"|"out"|"inout"|"variadic"|"table"

---@class dbquery.SchemaName
---@field database string|nil
---@field schema string

---@class dbquery.Catalog
---@field searchPath dbquery.SchemaName[] Where an unqualified name is looked for, in order.
---@field relations dbquery.Relation[]
---@field functions dbquery.Function[] One per overload.
---@field types dbquery.Type[]

---@class dbquery.Relation
---@field database string|nil
---@field schema string
---@field name string
---@field kind dbquery.RelationKind
---@field comment string|nil
---@field columns dbquery.Column[] In the relation's column order.

---@class dbquery.Column
---@field name string
---@field type string|nil Nil where the database records none, as sqlite allows.
---@field nullable boolean
---@field default string|nil
---@field generated "identity"|"stored"|"virtual"|nil How the database fills the column, so an insert leaves it out. A serial or auto-increment column is nil, because an insert may still set it.
---@field hidden boolean Left out of `*` and of an insert's column list, though a query may name it.
---@field labels string[]|nil The values of an enum column.
---@field comment string|nil

---@class dbquery.Function
---@field database string|nil
---@field schema string|nil Nil where functions belong to no schema, as in sqlite.
---@field name string
---@field kind dbquery.FunctionKind
---@field args dbquery.Argument[] In declared order. A call passes the in, inout, and variadic arguments, and a procedure's call passes its out arguments too.
---@field returnsSet boolean The function returns rows, so it can stand in `from`.
---@field result string|nil The result type, nil for a procedure or an untyped macro.
---@field comment string|nil

---@class dbquery.Argument
---@field name string|nil
---@field type string|nil
---@field mode dbquery.ArgumentMode
---@field default boolean A call may leave the argument out.

---@class dbquery.Type
---@field database string|nil
---@field schema string
---@field name string
---@field labels string[]|nil The values of an enum.

--- Throws unless `value` has the lua type `kind`, or is nil and `optional` is
--- set. The message names the field: "relations[2].name must be a string".
---@param value any
---@param kind type
---@param where string
---@param optional boolean|nil
local function expect(value, kind, where, optional)
  if type(value) == kind or (optional and value == nil) then
    return
  end
  error(where .. " must be a " .. kind .. (optional and " or nil" or ""), 0)
end

---@param list any
---@param where string
---@param each fun(item: any, at: string)
local function every(list, where, each)
  expect(list, "table", where)
  for index, item in ipairs(list) do
    local at = where .. "[" .. index .. "]"
    expect(item, "table", at)
    each(item, at)
  end
end

---@param item table
---@param at string
local function qualified(item, at)
  expect(item.database, "string", at .. ".database", true)
  expect(item.name, "string", at .. ".name")
  expect(item.comment, "string", at .. ".comment", true)
end

---@param column table
---@param at string
local function checkColumn(column, at)
  expect(column.name, "string", at .. ".name")
  expect(column.type, "string", at .. ".type", true)
  expect(column.nullable, "boolean", at .. ".nullable")
  expect(column.default, "string", at .. ".default", true)
  expect(column.generated, "string", at .. ".generated", true)
  expect(column.hidden, "boolean", at .. ".hidden")
  expect(column.labels, "table", at .. ".labels", true)
  expect(column.comment, "string", at .. ".comment", true)
end

---@param argument table
---@param at string
local function checkArgument(argument, at)
  expect(argument.name, "string", at .. ".name", true)
  expect(argument.type, "string", at .. ".type", true)
  expect(argument.mode, "string", at .. ".mode")
  expect(argument.default, "boolean", at .. ".default")
end

--- Returns what is wrong with `catalog`, or nil when it has the catalog's
--- shape.
---@param catalog any
---@return string|nil
function M.problem(catalog)
  local ok, err = pcall(function()
    expect(catalog, "table", "the catalog")
    every(catalog.searchPath, "searchPath", function(name, at)
      expect(name.database, "string", at .. ".database", true)
      expect(name.schema, "string", at .. ".schema")
    end)
    every(catalog.relations, "relations", function(relation, at)
      qualified(relation, at)
      expect(relation.schema, "string", at .. ".schema")
      expect(relation.kind, "string", at .. ".kind")
      every(relation.columns, at .. ".columns", checkColumn)
    end)
    every(catalog.functions, "functions", function(fn, at)
      qualified(fn, at)
      expect(fn.schema, "string", at .. ".schema", true)
      expect(fn.kind, "string", at .. ".kind")
      expect(fn.returnsSet, "boolean", at .. ".returnsSet")
      expect(fn.result, "string", at .. ".result", true)
      every(fn.args, at .. ".args", checkArgument)
    end)
    every(catalog.types, "types", function(item, at)
      qualified(item, at)
      expect(item.schema, "string", at .. ".schema")
      expect(item.labels, "table", at .. ".labels", true)
    end)
  end)
  return not ok and tostring(err) or nil
end

return M
