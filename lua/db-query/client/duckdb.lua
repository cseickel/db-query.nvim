--[[
Running statements through the duckdb cli.
]]

local duckdb = require("db-query.sql.dialect.duckdb")
local sql = require("db-query.sql")
local url = require("db-query.url")

---@type dbquery.Client
return {
  rows = { query = true, returning = true },
  delimited = "csv",
  embedded = true,
  dialect = duckdb,

  command = function(spec)
    local argv = { "duckdb" }
    local file = url.filePath(spec.connection)
    if file ~= "" then
      table.insert(argv, file)
    end

    if not spec.path then
      vim.list_extend(argv, { "-c", spec.statement })
      return { argv = argv }
    end

    -- COPY takes a quoted path, so it reaches an output directory whose name
    -- has a space in it, but its argument has to be a select.
    if spec.format == "csv" and spec.kind == "query" then
      local copy = string.format(
        "COPY (\n%s\n) TO '%s' (FORMAT csv, HEADER)",
        sql.stripTerminator(duckdb, spec.statement),
        (spec.path:gsub("'", "''"))
      )
      vim.list_extend(argv, { "-c", copy })
      return { argv = argv }
    end

    -- .output takes any statement, but splits its argument on whitespace and
    -- reads quotes as part of the name, so it writes to `staging` instead.
    vim.list_extend(argv, {
      "-c",
      ".mode " .. (spec.format == "csv" and "csv" or "duckbox"),
      "-c",
      ".headers on",
      "-c",
      ".output " .. spec.staging,
      "-c",
      spec.statement,
    })
    return { argv = argv, staged = true }
  end,
}
