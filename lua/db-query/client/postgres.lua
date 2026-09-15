--[[
Running statements through psql.
]]

local psql = require("db-query.sql.dialect.psql")
local sql = require("db-query.sql")
local url = require("db-query.url")

--- Returns the statement psql runs to fill the results file: wrapped in COPY
--- for csv, and as written for text, where psql's own table is the output.
---@param spec dbquery.CommandSpec
---@return string
local function rows(spec)
  local body = sql.stripTerminator(psql, spec.statement)
  if spec.format ~= "csv" then
    return body
  end
  return "COPY (\n" .. body .. "\n) TO STDOUT WITH (FORMAT csv, HEADER)"
end

--- psql meta-command sending query results to `file`, or back to stdout when
--- `file` is nil. psql reads backslash escapes inside a single-quoted
--- meta-command argument, so both marks have to be escaped.
---@param file string|nil
---@return string
local function sendTo(file)
  if not file then
    return "\\o"
  end
  return "\\o '" .. file:gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
end

---@type dbquery.Client
return {
  rows = { query = true, returning = true },
  delimited = "csv",
  dialect = psql,

  command = function(spec)
    local without, password = url.withoutPassword(spec.connection)
    local sessionFile = vim.fn.tempname() .. ".pid"
    local argv = { "psql", without, "-w", "--no-psqlrc", "-v", "ON_ERROR_STOP=1" }
    local script

    if spec.path then
      vim.list_extend(argv, { "-f", "-" })
      script = {
        sendTo(sessionFile),
        "SELECT pg_backend_pid();",
        sendTo(spec.path),
        rows(spec),
        -- Separate semicolon in case the statement ends in a line comment.
        ";",
        sendTo(nil),
        "",
      }
    else
      -- -e echoes statements so row counts are labeled.
      vim.list_extend(argv, { "-e", "-f", "-" })
      script = {
        "\\set ECHO none",
        sendTo(sessionFile),
        "SELECT pg_backend_pid();",
        sendTo(nil),
        "\\set ECHO queries",
        "\\timing on\n",
        spec.statement,
        ";",
        "",
      }
    end

    return {
      argv = argv,
      env = password and { PGPASSWORD = password } or nil,
      sessionFile = sessionFile,
      stdin = table.concat(script, "\n"),
    }
  end,

  cancel = function(connection, pid)
    local without, password = url.withoutPassword(connection)
    return {
      argv = {
        "psql",
        without,
        "-w",
        "--no-psqlrc",
        "-q",
        "-c",
        "SELECT pg_cancel_backend(" .. pid .. ")",
      },
      env = password and { PGPASSWORD = password } or nil,
    }
  end,
}
