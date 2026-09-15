--[[
The catalog of each database, read in the background and kept for the session.

- `get` returns what is known of a connection's catalog, and starts the first
  read of it.
- `refresh` reads it again, replacing a read still under way.

Nothing waits on a read. Until one finishes, `get` returns the catalog from
before it, or nil.

Each client file holds a built-in `catalog` function. The `catalog.clients`
setting replaces it for the clients it names.
]]

local client = require("db-query.client")
local config = require("db-query.config")
local shape = require("db-query.catalog.shape")
local url = require("db-query.url")

local M = {}

---@class dbquery.QueryOptions
---@field timeout integer|nil Milliseconds before the query is killed, nil to wait for it.

---@class dbquery.CatalogRequest
---@field client string The client's name, such as "postgres" or "duckdb".
---@field connection string The resolved url, password included.
---@field timeout integer|nil The `catalog.timeout` setting for a built-in function, and nil for one from `catalog.clients`.
---@field query fun(statement: string, opts: dbquery.QueryOptions|nil, callback: fun(output: string|nil, err: string|nil)) Runs `statement` through the client, opened read-only as `dbquery.CommandSpec.readonly` describes, and calls `callback` with what it printed, unaligned and with no header, or with why it failed.

--- Reads a database's catalog and calls `done` once with it, or with why it
--- could not.
---@alias dbquery.CatalogFetch fun(request: dbquery.CatalogRequest, done: fun(catalog: dbquery.Catalog|nil, err: string|nil))

---@class dbquery.CatalogEntry
---@field catalog dbquery.Catalog|nil The last catalog read.
---@field generation integer Counts reads, so a result from one that was replaced is dropped.
---@field processes dbquery.Process[] Queries the latest read started.

---@type table<string, dbquery.CatalogEntry>
local entries = {}

--- Returns what names `connection`'s database: its file for a client that
--- opens one, and its url without the password otherwise.
---@param connection string
---@param found dbquery.Client
---@return string
local function keyOf(connection, found)
  if found.embedded then
    return url.scheme(connection) .. ":" .. url.filePath(connection)
  end
  return (url.withoutPassword(connection))
end

---@param entry dbquery.CatalogEntry
local function stop(entry)
  for _, process in ipairs(entry.processes) do
    process:cancel()
  end
  entry.processes = {}
end

--- Reads the catalog of `connection` again, replacing any read still running,
--- and keeps the result when it has the catalog's shape. A read that fails
--- keeps the catalog from before it and shows why.
---@param connection string Resolved url.
function M.refresh(connection)
  local found = client.of(connection)
  if not found then
    return
  end
  local key = keyOf(connection, found)
  local entry = entries[key] or { generation = 0, processes = {} }
  entries[key] = entry
  stop(entry)
  entry.generation = entry.generation + 1

  -- Opening a missing file read-only fails, and until something creates it the
  -- database holds nothing.
  local file = found.embedded and url.filePath(connection) or ""
  if file ~= "" and not vim.uv.fs_stat(file) then
    entry.catalog = { searchPath = {}, relations = {}, functions = {}, types = {} }
    return
  end

  local generation, finished = entry.generation, false
  local custom = config.values.catalog.clients[found.name]

  local function current()
    return not finished and entry.generation == generation
  end

  ---@param catalog dbquery.Catalog|nil
  ---@param err string|nil
  local function done(catalog, err)
    if not current() then
      return
    end
    finished = true
    stop(entry)
    local problem = err or (catalog == nil and "no catalog was returned") or shape.problem(catalog)
    if problem then
      return vim.notify(
        string.format("db-query: could not read the %s catalog, :DBRefreshCatalog retries: %s", found.name, problem),
        vim.log.levels.ERROR
      )
    end
    entry.catalog = catalog
  end

  --- Calls `fn`, failing this read when it throws. A callback runs long after
  --- the catalog function returned, so its errors need catching of their own.
  local function guarded(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
      done(nil, tostring(err))
    end
  end

  ---@type dbquery.CatalogRequest
  local request = {
    client = found.name,
    connection = connection,
    timeout = not custom and config.values.catalog.timeout or nil,
    query = function(statement, opts, callback)
      if not current() then
        return
      end
      local process, err = client.value({
        connection = connection,
        statement = statement,
        timeout = (opts or {}).timeout,
        readonly = true,
      })
      if not process then
        return guarded(callback, nil, err or "the client could not start")
      end
      table.insert(entry.processes, process)
      process:onFinish(function()
        if current() then
          guarded(callback, process.status == "ok" and process.result.stdout or nil, process:reason())
        end
      end)
    end,
  }

  guarded(custom or found.catalog, request, done)
end

--- Returns the last catalog read for `connection`, or nil when none has been.
--- Starts the first read, and never starts another: a failed read waits for
--- `refresh`, so an unreachable database is not asked again on every call.
---@param connection string Resolved url.
---@return dbquery.Catalog|nil
function M.get(connection)
  local found = client.of(connection)
  if not found then
    return nil
  end
  local key = keyOf(connection, found)
  if not entries[key] then
    M.refresh(connection)
  end
  return entries[key] and entries[key].catalog
end

return M
