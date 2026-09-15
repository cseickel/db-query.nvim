--[[
Turning a connection and a statement into a command line.

Every client writes its transcript to stdout and its errors to stderr, both of
which the caller sends to the log. Rows go to a file of their own, which the
client writes wherever it can. Each client is a file in this directory, keyed
here by the url schemes that reach it.
]]

local Process = require("db-query.process")
local url = require("db-query.url")

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

---@class dbquery.CommandSpec
---@field connection string
---@field statement string
---@field format dbquery.CommandFormat
---@field kind dbquery.RowKind|nil
---@field path string|nil Results file, set whenever `kind` is.
---@field staging string|nil Whitespace-free path a client may write to instead of `path`.
---@field readonly boolean Keeps the statement from writing: a sqlite or duckdb file is opened read-only, and postgres runs it in a read-only transaction. mysql and mariadb run it in a read-only transaction too, which refuses row changes, but a `create`, `alter`, or `drop` commits that transaction and runs.

---@class dbquery.Client
---@field name string Names the client in `catalog.clients`.
---@field catalog dbquery.CatalogFetch Built-in way to read the database's catalog.
---@field rows table<dbquery.RowKind, boolean> Row kinds this client writes to a file.
---@field delimited string Extension for csv format: csv or tsv.
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

--- Returns true when `connection` is a file the client opens itself, with no
--- server to reach.
---@param connection string
---@return boolean
function M.embedded(connection)
  local client = CLIENTS[url.scheme(connection)]
  return client ~= nil and client.embedded == true
end

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
local function known(connection)
  local client = M.of(connection)
  if not client then
    -- Show scheme, not full url, to avoid exposing expanded $VAR values.
    vim.notify("no client known for " .. url.scheme(connection), vim.log.levels.ERROR)
  end
  return client
end

--- Returns the dialect `connection`'s client reads sql by.
---
--- Returns nil and shows an error when no client is known for the url scheme.
---@param connection string
---@return dbquery.Dialect|nil
function M.dialect(connection)
  local client = known(connection)
  return client and client.dialect
end

--- Returns the command to run `spec.statement` against `spec.connection`.
---
--- Returns nil and shows an error when no client is known for the url scheme.
---@param spec dbquery.CommandSpec
---@return dbquery.Command|nil
function M.command(spec)
  local client = known(spec.connection)
  return client and client.command(spec)
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

---@class dbquery.ValueSpec
---@field connection string
---@field statement string
---@field timeout integer|nil Milliseconds before the client is killed, nil to wait for it.
---@field readonly boolean

--- Starts `spec.statement` in the "value" format, so its result is the stdout
--- the process finishes with. Shows an error and returns nil when no client is
--- known for the url. Returns nil and the reason when the client cannot start.
---@param spec dbquery.ValueSpec
---@return dbquery.Process|nil
---@return string|nil
function M.value(spec)
  local command = M.command({
    connection = spec.connection,
    statement = spec.statement,
    format = "value",
    readonly = spec.readonly,
  })
  if not command then
    return nil
  end
  return Process.start({
    command = command,
    timeout = spec.timeout,
    askServer = function()
      return command.sessionFile ~= nil and M.cancel(spec.connection, command.sessionFile)
    end,
  })
end

return M
