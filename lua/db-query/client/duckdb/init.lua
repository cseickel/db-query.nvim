--[[
Running statements through the duckdb cli.
]]

local duckdb = require("db-query.sql.dialect.duckdb")
local query = require("db-query.client.query")
local sql = require("db-query.sql")
local url = require("db-query.client.url")

---@type dbquery.Client
return {
  name = "duckdb",
  catalog = require("db-query.client.duckdb.catalog"),
  definition = require("db-query.client.duckdb.definition"),
  references = require("db-query.client.duckdb.references"),
  rowKinds = { query = true, returning = true },
  csvExtension = "csv",
  embedded = true,
  dialect = duckdb,

  command = function(spec)
    local argv = { "duckdb" }
    if spec.format == "value" then
      vim.list_extend(argv, { "-noheader", "-list" })
    end
    local file = url.filePath(spec.connection)
    if file ~= "" then
      -- An in-memory database refuses -readonly, and has no file to protect.
      if spec.readonly then
        table.insert(argv, "-readonly")
      end
      table.insert(argv, file)
    end

    if not spec.path then
      vim.list_extend(argv, { "-c", spec.statement })
      return { argv = argv }
    end

    -- COPY takes a quoted path, so it reaches an output directory whose name
    -- has a space in it, but its argument has to be a select.
    if spec.format == "csv" and spec.kind == "query" then
      local copy = "COPY (\n" .. sql.stripTerminator(duckdb, spec.statement) .. "\n) TO "
        .. query.literal(spec.path) .. " (FORMAT csv, HEADER)"
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
