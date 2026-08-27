--[[
What each database's own command line client needs to be told.

A client is named by the scheme of the connection url, and knows two things:
how to be asked to run a statement, and how the server it is talking to can be
asked to stop. A client that is the database rather than a client of one has no
server to ask and no second connection to ask on, so it has no cancel.

Only psql has a script mode worth the name, echoing each statement and
reporting its row count and duration. Every other client is handed the script
unchanged and prints whatever it prints.
]]

local sql = require("db-query.sql")
local url = require("db-query.url")

local M = {}

---@class dbquery.Command
---@field argv string[]
---@field extension string What the client will write: csv, tsv, or log.
---@field env table<string, string>|nil
---@field stdin string|nil
---@field sessionFile string|nil Where the client writes the server session it holds.

---@class dbquery.Client
---@field command fun(connection: string, statement: string, mode: dbquery.Mode): dbquery.Command
---@field cancel? fun(connection: string, pid: integer): { argv: string[], env: table<string, string>|nil }

--- A script command, whose output is the client's own transcript rather than
--- rows in a delimited format.
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

--- Tells psql to put the backend pid in `file` rather than in its output, so
--- neither the transcript nor the rows have to be picked apart to find it.
--- `echoing` says whether the statement echo has to be turned off around it
--- and back on afterwards, which script mode needs and export mode must not
--- do, since export mode never turned it on.
---@param file string
---@param echoing boolean
---@return string
local function backendPid(file, echoing)
  local lines = { "\\o '" .. file .. "'", "SELECT pg_backend_pid();", "\\o" }
  if echoing then
    table.insert(lines, 1, "\\set ECHO none")
    table.insert(lines, "\\set ECHO queries")
  end
  return table.concat(lines, "\n") .. "\n"
end

--- What the mysql client needs to connect, which is not a url.
---@param connection string mysql://user:password@host:port/database
---@return { argv: string[], env: table<string, string>|nil }
local function mysqlArguments(connection)
  local rest = connection:gsub("^mysql://", "")
  local authority, path = rest:match("^([^/]*)(.*)$")
  -- The last `@` of the authority, so a password holding one is not cut short.
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
    -- --no-psqlrc leaves this module the only thing shaping the output.
    local argv = { "psql", without, "-w", "--no-psqlrc", "-v", "ON_ERROR_STOP=1" }
    local sessionFile = vim.fn.tempname() .. ".pid"

    if mode == "script" then
      -- -e echoes each statement before it runs, so the row count and the
      -- duration underneath it are labelled by the statement they belong to.
      vim.list_extend(argv, { "-e", "-f", "-" })
      return {
        argv = argv,
        extension = "log",
        env = env,
        sessionFile = sessionFile,
        -- The trailing semicolon is separated from the last statement because
        -- a script may end inside a line comment, which would swallow it.
        stdin = backendPid(sessionFile, true) .. "\\timing on\n" .. statement .. "\n;\n",
      }
    end

    -- -q keeps psql's command tags out of the rows.
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
    -- `COPY ... TO '/dev/stdout'` reopens stdout, which fails when the caller
    -- gives the process a socket rather than a file.
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
    -- The password goes in the environment because a command line is readable
    -- by every process on the machine.
    if mode == "script" then
      return script({ argv = argv, env = connects.env })
    end
    return { argv = argv, extension = "tsv", env = connects.env }
  end,
}

--- How to ask `connection`'s client to run `statement`. In export mode the
--- client writes delimited rows to stdout and the extension names the
--- delimiter it wrote with. In script mode it writes its own transcript.
---
--- Nil for a url no client is known for, already reported.
---@param connection string
---@param statement string
---@param mode dbquery.Mode
---@return dbquery.Command|nil
function M.command(connection, statement, mode)
  local client = CLIENTS[url.scheme(connection)]
  if not client then
    -- The scheme rather than the url, which by here holds whatever a `$VAR` in
    -- it named, and `:messages` is kept for the rest of the session.
    vim.notify("no client known for " .. url.scheme(connection), vim.log.levels.ERROR)
    return nil
  end
  return client.command(connection, statement, mode)
end

--- The server session recorded in `file`, nil while the client has yet to
--- write one.
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

--- Asks `connection`'s server to cancel the query running in the session
--- recorded in `file`. False when there is no server to ask or no session
--- recorded yet, so the caller can fall back to interrupting the client.
---@param connection string
---@param file string
---@return boolean asked
function M.cancel(connection, file)
  local client = CLIENTS[url.scheme(connection)]
  if not (client and client.cancel) then
    return false
  end
  local pid = recorded(file)
  if not pid then
    return false
  end

  -- Nothing waits on this. The client being cancelled reports the outcome in
  -- the pane, which is where the reader is already looking.
  local command = client.cancel(connection, pid)
  vim.system(command.argv, { env = command.env, detach = true })
  return true
end

--- Runs `statement` against `connection` as a script and waits for it,
--- returning what the client printed. Nil for a failure, already reported.
---
--- This is for a statement whose output is small and wanted right now, such as
--- the ddl that names a parquet file as a view. Anything a user asked for runs
--- as a Run instead, which neither blocks nor holds its output in memory.
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
  -- Nothing here can be cancelled, so the session the client recorded was only
  -- ever going to be read by a Run.
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
