--[[
The clients that run sql, keyed by url scheme, and the command line each runs
a statement with.
]]

local Process = require("db-query.query.process")
local url = require("db-query.client.url")

local M = {}

--- How the client prints: "text" and "csv" as the user asked, or "value" for
--- the statement's result alone, unaligned and with no header, echo, or
--- timing, for output read back into lua.
---@alias dbquery.CommandFormat dbquery.Format|"value"

---@class dbquery.Command
---@field argv string[]
---@field env table<string, string>|nil
---@field stdin string|nil
---@field stdout string|nil File the shell must catch stdout in, for a client that cannot write rows itself.
---@field staged boolean|nil Client wrote rows to `spec.staging`, to be moved onto the results file.
---@field sessionFile string|nil Path where the client writes the backend pid.
---@field countFile string|nil Path where the client writes how many rows it wrote to `spec.path`.

---@class dbquery.CommandSpec
---@field connection string
---@field statement string
---@field format dbquery.CommandFormat
---@field kind dbquery.RowKind|nil
---@field path string|nil Results file, set whenever `kind` is.
---@field staging string|nil Whitespace-free path a client may write to instead of `path`.
---@field readonly boolean Runs the statement so it cannot change data.

---@class dbquery.Client
---@field name string Names the client in `catalog.clients`.
---@field catalog dbquery.CatalogFetch Built-in way to read the database's catalog.
---@field definition fun(request: dbquery.CatalogRequest, target: dbquery.Target, done: fun(ddl: string|nil, err: string|nil)) Reads the DDL of a relation, or of a column's relation, or of every overload of a function.
---@field references fun(request: dbquery.CatalogRequest, target: dbquery.Target, done: fun(references: dbquery.Reference[]|nil, err: string|nil)) Finds the relations and routines that depend on what `definition` would read.
---@field rowKinds table<dbquery.RowKind, boolean> Row kinds this client writes to a file.
---@field csvExtension string Extension for csv format: csv or tsv.
---@field command fun(spec: dbquery.CommandSpec): dbquery.Command
---@field cancel? fun(connection: string, pid: integer): { argv: string[], env: table<string, string>|nil }
---@field embedded? boolean The database is a file the client opens itself, with no server to reach.
---@field dialect dbquery.Dialect The rules the client reads sql by.

local postgres = require("db-query.client.postgres")
local mysql = require("db-query.client.mysql")

---@type table<string, dbquery.Client>
local CLIENTS = {
  postgres = postgres,
  postgresql = postgres,
  duckdb = require("db-query.client.duckdb"),
  sqlite = require("db-query.client.sqlite"),
  mysql = mysql.mysql,
  mariadb = mysql.mariadb,
}

--- Returns the client for `connection`'s scheme, or nil when none is known.
---@param connection string
---@return dbquery.Client|nil
function M.of(connection)
  return CLIENTS[url.scheme(connection)]
end

--- Returns the client for `connection`'s scheme, or nil after showing an error
--- when no client is known for it.
---@param connection string
---@return dbquery.Client|nil
function M.known(connection)
  local dbClient = M.of(connection)
  if not dbClient then
    -- Show scheme, not full url, to avoid exposing expanded $VAR values.
    vim.notify("no client known for " .. url.scheme(connection), vim.log.levels.ERROR)
  end
  return dbClient
end

--- Sends a cancel request to the server for the session recorded in
--- `sessionFile`. Returns false when the client has no server-side cancel or no
--- session pid has been recorded yet.
---@param dbClient dbquery.Client
---@param connection string
---@param sessionFile string
---@return boolean
function M.cancel(dbClient, connection, sessionFile)
  if not dbClient.cancel then
    return false
  end
  local pid = Process.recorded(sessionFile)
  if not pid then
    return false
  end

  local command = dbClient.cancel(connection, pid)
  vim.system(command.argv, { env = command.env, detach = true })
  return true
end

---@class dbquery.ValueSpec
---@field client dbquery.Client
---@field connection string
---@field statement string
---@field timeout integer|nil Milliseconds before the client is killed, nil to wait for it.
---@field readonly boolean

--- Starts `spec.statement` in the "value" format, so its result is the stdout
--- the process finishes with. Returns nil and the reason when the client
--- cannot start.
---@param spec dbquery.ValueSpec
---@return dbquery.Process|nil
---@return string|nil
function M.value(spec)
  local command = spec.client.command({
    connection = spec.connection,
    statement = spec.statement,
    format = "value",
    readonly = spec.readonly,
  })
  return Process.start({
    command = command,
    timeout = spec.timeout,
    askServer = function()
      return command.sessionFile ~= nil and M.cancel(spec.client, spec.connection, command.sessionFile)
    end,
  })
end

--- Runs `spec.statement` as `value` does, and calls `callback` once with what
--- it printed, or with why it failed. Returns the process, or nil after
--- calling `callback` when the client cannot start.
---@param spec dbquery.ValueSpec
---@param callback fun(output: string|nil, err: string|nil)
---@return dbquery.Process|nil
function M.read(spec, callback)
  local process, err = M.value(spec)
  if not process then
    callback(nil, err or "the client could not start")
    return nil
  end
  process:onFinish(function()
    callback(process.status == "ok" and process.result.stdout or nil, process:reason())
  end)
  return process
end

return M
