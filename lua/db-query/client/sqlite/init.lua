--[[
Running statements through sqlite3.
]]

local url = require("db-query.client.url")

---@type dbquery.Client
return {
  name = "sqlite",
  catalog = require("db-query.client.sqlite.catalog"),
  definition = require("db-query.client.sqlite.definition"),
  references = require("db-query.client.sqlite.references"),
  rowKinds = { query = true, returning = true },
  csvExtension = "csv",
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
