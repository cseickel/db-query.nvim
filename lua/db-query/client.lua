--[[
Turning a connection and a statement into a command line.

Every client writes its transcript to stdout and its errors to stderr, both of
which the caller sends to the log. Rows go to a file of their own, which the
client writes wherever it can.
]]

local sql = require("db-query.sql")
local url = require("db-query.url")

local M = {}

---@class dbquery.Command
---@field argv string[]
---@field env table<string, string>|nil
---@field stdin string|nil
---@field stdout string|nil File the shell must catch stdout in, for a client that cannot write rows itself.
---@field staged boolean|nil Client wrote rows to `spec.staging`, to be moved onto the results file.
---@field sessionFile string|nil Path where the client writes the backend pid.

---@class dbquery.CommandSpec
---@field connection string
---@field statement string
---@field format dbquery.Format
---@field kind dbquery.RowKind|nil
---@field path string|nil Results file, set whenever `kind` is.
---@field staging string|nil Whitespace-free path a client may write to instead of `path`.

---@class dbquery.Client
---@field rows table<dbquery.RowKind, boolean> Row kinds this client writes to a file.
---@field delimited string Extension for csv format: csv or tsv.
---@field command fun(spec: dbquery.CommandSpec): dbquery.Command
---@field cancel? fun(connection: string, pid: integer): { argv: string[], env: table<string, string>|nil }

--- Returns the statement psql runs to fill the results file: wrapped in COPY
--- for csv, and as written for text, where psql's own table is the output.
---@param spec dbquery.CommandSpec
---@return string
local function pgRows(spec)
  local body = sql.stripTerminator(spec.statement)
  if spec.format ~= "csv" then
    return body
  end
  return "COPY (\n" .. body .. "\n) TO STDOUT WITH (FORMAT csv, HEADER)"
end

--- Converts a mysql:// url into command-line arguments and environment.
---@param connection string mysql://user:password@host:port/database
---@return { argv: string[], env: table<string, string>|nil }
local function mysqlArguments(connection)
  local rest = connection:gsub("^mysql://", "")
  local authority, path = rest:match("^([^/]*)(.*)$")
  -- Split on last @ to handle passwords containing @.
  local credentials, location = authority:match("^(.*)@([^@]*)$")
  if not credentials then
    credentials, location = "", authority
  end

  local user, password = credentials:match("^([^:]*):?(.*)$")
  local host, port = location:match("^([^:]*):?(.*)$")
  local database = path:gsub("^/", "")

  local arguments = {}
  local function add(flag, value)
    if value ~= "" then
      vim.list_extend(arguments, { flag, value })
    end
  end
  add("-h", url.decoded(host))
  add("-P", port)
  add("-u", url.decoded(user))
  if database ~= "" then
    table.insert(arguments, url.decoded(database))
  end

  return {
    argv = arguments,
    env = password ~= "" and { MYSQL_PWD = url.decoded(password) } or nil,
  }
end

---@type table<string, dbquery.Client>
local CLIENTS = {}

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

CLIENTS.postgres = {
  rows = { query = true, returning = true },
  delimited = "csv",

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
        pgRows(spec),
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
CLIENTS.postgresql = CLIENTS.postgres

CLIENTS.duckdb = {
  rows = { query = true, returning = true },
  delimited = "csv",

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
        sql.stripTerminator(spec.statement),
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

CLIENTS.sqlite = {
  rows = { query = true, returning = true },
  delimited = "csv",

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

CLIENTS.mysql = {
  rows = { query = true },
  delimited = "tsv",

  command = function(spec)
    local connects = mysqlArguments(spec.connection)
    local argv = { "mysql" }
    -- --batch prints tab-separated rows in place of the ascii table.
    if spec.format == "csv" and spec.path then
      table.insert(argv, "--batch")
    end
    vim.list_extend(argv, connects.argv)
    vim.list_extend(argv, { "-e", spec.statement })
    -- Password in environment because command lines are world-readable.
    -- mysql has no way to file rows itself, so the shell catches them.
    return { argv = argv, env = connects.env, stdout = spec.path }
  end,
}

--- Returns the extension for the results file, or nil when the run writes no
--- rows and everything belongs in the log.
---@param connection string
---@param kind dbquery.RowKind|nil
---@param format dbquery.Format
---@return string|nil
function M.target(connection, kind, format)
  local client = CLIENTS[url.scheme(connection)]
  if not (client and kind and client.rows[kind]) then
    return nil
  end
  return format == "csv" and client.delimited or "txt"
end

--- Returns the command to run `spec.statement` against `spec.connection`.
---
--- Returns nil and shows an error when no client is known for the url scheme.
---@param spec dbquery.CommandSpec
---@return dbquery.Command|nil
function M.command(spec)
  local client = CLIENTS[url.scheme(spec.connection)]
  if not client then
    -- Show scheme, not full url, to avoid exposing expanded $VAR values.
    vim.notify("no client known for " .. url.scheme(spec.connection), vim.log.levels.ERROR)
    return nil
  end
  return client.command(spec)
end

--- Returns the server pid from `file`, or nil if not yet written.
---@param file string
---@return integer|nil
local function recorded(file)
  local handle = io.open(file, "r")
  if not handle then
    return nil
  end
  local text = handle:read("*a")
  handle:close()
  return tonumber(text:match("%d+"))
end

--- Sends a cancel request to the server for the session recorded in `file`.
---
--- Returns false when the client has no server-side cancel (caller should
--- SIGINT the client instead) or when no session pid has been recorded yet.
---@param connection string
---@param file string
---@return boolean
function M.cancel(connection, file)
  local client = CLIENTS[url.scheme(connection)]
  if not (client and client.cancel) then
    return false
  end
  local pid = recorded(file)
  if not pid then
    return false
  end

  local command = client.cancel(connection, pid)
  vim.system(command.argv, { env = command.env, detach = true })
  return true
end

--- Runs `statement` synchronously and returns the output.
---
--- This is not used internally, but is provided as a convenience for
--- external use.
---
--- Returns nil and shows an error on failure.
---@param connection string
---@param statement string
---@return string|nil
function M.run(connection, statement)
  local command = M.command({
    connection = connection,
    statement = statement,
    format = "text",
  })
  if not command then
    return nil
  end

  local result = vim.system(command.argv, {
    text = true,
    env = command.env,
    stdin = command.stdin,
  }):wait()
  if command.sessionFile then
    os.remove(command.sessionFile)
  end

  if result.code ~= 0 then
    vim.notify(vim.trim(result.stderr or "query failed"), vim.log.levels.ERROR)
    return nil
  end
  return result.stdout or ""
end

return M
