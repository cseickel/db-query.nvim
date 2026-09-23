--[[
Helpers for the `definition` function of each client, which reads an object's
DDL. Each client's own function is a file in this directory.
]]

local M = {}

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

--- Returns `statements` as one script, each ending in `;` and separated by a
--- blank line.
---@param statements string[]
---@return string
function M.script(statements)
  return table.concat(vim.tbl_map(function(statement)
    return (vim.trim(statement):gsub("%s*;$", "")) .. ";"
  end, statements), "\n\n") .. "\n"
end

return M
