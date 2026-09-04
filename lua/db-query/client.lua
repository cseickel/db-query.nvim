local sql = require("db-query.sql")
local url = require("db-query.url")

local M = {}

---@class dbquery.Command
---@field argv string[]
---@field extension string Output format: csv, tsv, or log.
---@field env table<string, string>|nil
---@field stdin string|nil
---@field sessionFile string|nil Path where the client writes the backend pid.

---@class dbquery.Client
---@field command fun(connection: string, statement: string, mode: dbquery.Mode): dbquery.Command
---@field cancel? fun(connection: string, pid: integer): { argv: string[], env: table<string, string>|nil }

---@param command { argv: string[], stdin: string|nil, env: table<string, string>|nil }
---@return dbquery.Command
local function script(command)
  return {
    argv = command.argv,
    extension = "log",
    stdin = command.stdin,
    env = command.env,
  }
end

--- Returns psql commands that write the backend pid to `file`.
---@param file string
---@return string
local function backendPid(file)
  local lines = { "\\o '" .. file .. "'", "SELECT pg_backend_pid();", "\\o", "" }
  return table.concat(lines, "\n")
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

CLIENTS.postgres = {
  command = function(connection, statement, mode)
    local without, password = url.withoutPassword(connection)
    local env = password and { PGPASSWORD = password } or nil
    local argv = { "psql", without, "-w", "--no-psqlrc", "-v", "ON_ERROR_STOP=1" }
    local sessionFile = vim.fn.tempname() .. ".pid"

    if mode == "script" then
      -- -e echoes statements so row counts are labeled.
      vim.list_extend(argv, { "-e", "-f", "-" })
      local script = {
        "\\set ECHO none",
        backendPid(sessionFile, true),
        "\\set ECHO queries",
        "\\timing on\n",
        statement,
        -- Separate semicolon in case the statement ends in a line comment.
        ";\n",
      }
      return {
        argv = argv,
        extension = "log",
        env = env,
        sessionFile = sessionFile,
        stdin = table.concat(script, "\n"),
      }
    end

    vim.list_extend(argv, { "-q", "-f", "-" })
    local copy = "COPY (\n"
      .. sql.stripTerminator(statement)
      .. "\n) TO STDOUT WITH (FORMAT csv, HEADER)"
    return {
      argv = argv,
      extension = "csv",
      env = env,
      sessionFile = sessionFile,
      stdin = backendPid(sessionFile, false) .. copy .. "\n;\n",
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
  command = function(connection, statement, mode)
    local argv = { "duckdb" }
    local path = url.filePath(connection)
    if path ~= "" then
      table.insert(argv, path)
    end
    if mode == "script" then
      return script({ argv = vim.list_extend(argv, { "-c", statement }) })
    end
    -- COPY TO '/dev/stdout' fails when stdout is a socket, so use -csv instead.
    vim.list_extend(argv, { "-csv", "-header", "-c", statement })
    return { argv = argv, extension = "csv" }
  end,
}

CLIENTS.sqlite = {
  command = function(connection, statement, mode)
    local path = url.filePath(connection)
    if mode == "script" then
      return script({ argv = { "sqlite3", path, statement } })
    end
    return {
      argv = { "sqlite3", "-csv", "-header", path, statement },
      extension = "csv",
    }
  end,
}

CLIENTS.mysql = {
  command = function(connection, statement, mode)
    local connects = mysqlArguments(connection)
    local argv = { "mysql", "--batch" }
    vim.list_extend(argv, connects.argv)
    vim.list_extend(argv, { "-e", statement })
    -- Password in environment because command lines are world-readable.
    if mode == "script" then
      return script({ argv = argv, env = connects.env })
    end
    return { argv = argv, extension = "tsv", env = connects.env }
  end,
}

--- Returns the command to run `statement` against `connection`.
---
--- In export mode, the client writes delimited rows to stdout; the extension
--- indicates the delimiter. In script mode, the client writes its transcript.
---
--- Returns nil and shows an error when no client is known for the url scheme.
---@param connection string
---@param statement string
---@param mode dbquery.Mode
---@return dbquery.Command|nil
function M.command(connection, statement, mode)
  local client = CLIENTS[url.scheme(connection)]
  if not client then
    -- Show scheme, not full url, to avoid exposing expanded $VAR values.
    vim.notify("no client known for " .. url.scheme(connection), vim.log.levels.ERROR)
    return nil
  end
  return client.command(connection, statement, mode)
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
  local command = M.command(connection, statement, "script")
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
