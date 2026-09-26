--[[
Helpers for each client's `definition` and `references` functions, which read
an object's DDL and find what depends on it. Each client's `definition` is a
file in this directory, and its `references` is a file in `../references`.
]]

local lex = require("db-query.sql.lex")

local M = {}

--- An object that depends on another, as a client's `references` finds it.
---@class dbquery.Reference
---@field database string|nil
---@field schema string|nil
---@field name string
---@field routine boolean A function or procedure, rather than a relation.

--- Returns `text` as a sql string literal.
---@param text string
---@return string
function M.literal(text)
  return "'" .. text:gsub("'", "''") .. "'"
end

--- Returns `name` in double quotes, the way postgres, sqlite, and duckdb quote
--- a name.
---@param name string
---@return string
function M.identifier(name)
  return '"' .. name:gsub('"', '""') .. '"'
end

--- Returns a `like` pattern, as a string literal, matching text that holds
--- `name` anywhere. The pattern escapes with `!`, so a statement using it adds
--- `escape '!'`.
---@param name string
---@return string
function M.containing(name)
  return M.literal("%" .. name:gsub("[!%%_]", "!%0") .. "%")
end

--- Returns `statements` as one script, each ending in `;` and separated by a
--- blank line.
---@param statements string[]
---@return string
function M.script(statements)
  return table.concat(vim.tbl_map(function(statement)
    return (vim.trim(statement):gsub("%s*;$", "")) .. ";"
  end, statements), "\n\n") .. "\n"
end

--- Returns true when `text`, read by `dialect`, names `name` as a word or a
--- quoted identifier, and not inside a string or a comment.
---@param dialect dbquery.Dialect
---@param text string
---@param name string
---@return boolean
function M.mentions(dialect, text, name)
  local lower = name:lower()
  for _, token in ipairs(lex.tokens(dialect, text)) do
    if (token.kind == "word" and token.lower == lower) or (token.kind == "quoted" and token.text:sub(2, -2) == name) then
      return true
    end
  end
  return false
end

--- Returns the references in `rows`, each once. A row holding `text` came from
--- a search of that text, and is kept only when the text names `name`.
---@param dialect dbquery.Dialect
---@param rows table[] Rows with `database`, `schema`, `name`, `routine`, and `text`. mysql writes `routine` as 1 or 0.
---@param name string
---@return dbquery.Reference[]
function M.references(dialect, rows, name)
  local found, seen = {}, {}
  for _, row in ipairs(rows) do
    local routine = row.routine == true or row.routine == 1
    local key = table.concat({ row.database or "", row.schema or "", row.name, tostring(routine) }, "\0")
    if not seen[key] and (row.text == nil or M.mentions(dialect, row.text, name)) then
      seen[key] = true
      table.insert(found, { database = row.database, schema = row.schema, name = row.name, routine = routine })
    end
  end
  return found
end

return M
