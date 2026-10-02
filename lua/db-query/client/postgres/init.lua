--[[
Builds the psql command lines that run a statement and cancel one.
]]

local psql = require("db-query.sql.dialect.psql")
local sql = require("db-query.sql")
local url = require("db-query.client.url")

--- Returns `file` quoted as a psql meta-command argument. psql reads backslash
--- escapes inside the single quotes, so both marks have to be escaped.
---@param file string
---@return string
local function quotedPath(file)
  return "'" .. file:gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
end

--- Returns the psql meta-command that sends query results to `file`, or back
--- to stdout when `file` is nil.
---@param file string|nil
---@return string
local function sendTo(file)
  if not file then
    return "\\o"
  end
  return "\\o " .. quotedPath(file)
end

--- Returns the psql command line that connects to `connection`, and the
--- environment holding its password, which stays off the command line because
--- every process on the machine can read that.
---@param connection string
---@return string[] argv
---@return table<string, string>|nil env
local function login(connection)
  local safeUrl, password = url.withoutPassword(connection)
  return { "psql", safeUrl, "-w", "--no-psqlrc" }, password and { PGPASSWORD = password } or nil
end

---@type dbquery.Client
return {
  name = "postgres",
  catalog = require("db-query.client.postgres.catalog"),
  definition = require("db-query.client.postgres.definition"),
  references = require("db-query.client.postgres.references"),
  rowKinds = { query = true, returning = true },
  csvExtension = "csv",
  dialect = psql,

  command = function(spec)
    local argv, env = login(spec.connection)
    vim.list_extend(argv, { "-v", "ON_ERROR_STOP=1" })
    local sessionFile = vim.fn.tempname() .. ".pid"
    local recordPid = { sendTo(sessionFile), "SELECT pg_backend_pid();", sendTo(nil) }
    ---@type string|nil
    local countFile = nil
    local script

    if spec.format == "value" then
      vim.list_extend(argv, { "-A", "-t", "-q", "-f", "-" })
      script = vim.list_extend(recordPid, {
        spec.readonly and "BEGIN READ ONLY;" or "",
        spec.statement,
        ";",
        spec.readonly and "ROLLBACK;" or "",
        "",
      })
    elseif spec.path then
      countFile = vim.fn.tempname() .. ".rows"
      vim.list_extend(argv, { "-f", "-" })
      local body = sql.stripTerminator(psql, spec.statement)
      script = vim.list_extend(recordPid, {
        -- Quiet keeps psql from printing COPY's status line.
        "\\set QUIET on",
        spec.format == "csv" and ("COPY (\n" .. body .. "\n) TO STDOUT WITH (FORMAT csv, HEADER)") or body,
        -- With \o, psql drops COPY's result, and :ROW_COUNT with it.
        "\\g " .. quotedPath(spec.path),
        sendTo(countFile),
        "\\qecho :ROW_COUNT",
        sendTo(nil),
        "",
      })
    else
      -- -e echoes statements so row counts are labeled.
      vim.list_extend(argv, { "-e", "-f", "-" })
      script = { "\\set ECHO none" }
      vim.list_extend(script, recordPid)
      vim.list_extend(script, {
        "\\set ECHO queries",
        "\\timing on",
        spec.statement,
        ";",
        "",
      })
    end

    return {
      argv = argv,
      env = env,
      sessionFile = sessionFile,
      countFile = countFile,
      stdin = table.concat(script, "\n"),
    }
  end,

  cancel = function(connection, pid)
    local argv, env = login(connection)
    return {
      argv = vim.list_extend(argv, { "-q", "-c", "SELECT pg_cancel_backend(" .. pid .. ")" }),
      env = env,
    }
  end,
}
