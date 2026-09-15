--[[
Running statements through sqlite3.
]]

local url = require("db-query.url")

---@type dbquery.Client
return {
  rows = { query = true, returning = true },
  delimited = "csv",
  embedded = true,
  dialect = require("db-query.sql.dialect.sqlite"),

  command = function(spec)
    local file = url.filePath(spec.connection)
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
