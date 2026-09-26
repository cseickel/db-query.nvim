--[[
The catalog of each database, read in the background and saved to disk for the
next session. Nothing waits on a read: until one finishes, `get` returns the
catalog from before it, or nil.
]]

local client = require("db-query.client")
local config = require("db-query.config")
local mainloop = require("db-query.mainloop")
local Progress = require("db-query.query.progress")
local saved = require("db-query.catalog.saved")
local shape = require("db-query.catalog.shape")
local url = require("db-query.client.url")

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
---@field started integer|nil hrtime the read under way started, nil when none is.

---@type table<string, dbquery.CatalogEntry>
local entries = {}

local NOTICE_AFTER_MS = 2000

--- Stops the timer redrawing winbars and statuslines while any read runs, so
--- `statusline` spins. Nil while no read runs.
---@type fun()|nil
local stopRedraws = nil

---@return boolean
local function anyReading()
  for _, entry in pairs(entries) do
    if entry.started then
      return true
    end
  end
  return false
end

--- Starts the redraw timer when a read is under way, and stops it when none is.
local function updateRedraws()
  if anyReading() and not stopRedraws then
    stopRedraws = mainloop.every(Progress.FRAME_TIME, function()
      vim.api.nvim__redraw({ statusline = true, winbar = true })
    end)
  elseif stopRedraws and not anyReading() then
    stopRedraws()
    stopRedraws = nil
    vim.api.nvim__redraw({ statusline = true, winbar = true })
  end
end

--- Returns what names `resolved`'s database: its file for a client that opens
--- one, and its url without the password otherwise.
---@param resolved string
---@param dbClient dbquery.Client
---@return string
local function keyOf(resolved, dbClient)
  if dbClient.embedded then
    return url.scheme(resolved) .. ":" .. url.filePath(resolved)
  end
  return (url.withoutPassword(resolved))
end

---@param entry dbquery.CatalogEntry
local function stop(entry)
  for _, process in ipairs(entry.processes) do
    process:cancel()
  end
  entry.processes = {}
end

--- Reads the catalog of `resolved` again, replacing any read still running,
--- and keeps the result when it has the catalog's shape. A read that fails
--- keeps the catalog from before it and shows why.
---@param resolved string Resolved url.
function M.refresh(resolved)
  local dbClient = client.of(resolved)
  if not dbClient then
    return
  end
  local key = keyOf(resolved, dbClient)
  if not entries[key] then
    entries[key] = { catalog = saved.load(key), generation = 0, processes = {} }
  end
  local entry = entries[key]
  stop(entry)
  entry.generation = entry.generation + 1

  -- Opening a missing file read-only fails, and until something creates it the
  -- database holds nothing.
  local file = dbClient.embedded and url.filePath(resolved) or ""
  if file ~= "" and not vim.uv.fs_stat(file) then
    entry.catalog = { searchPath = {}, relations = {}, functions = {}, types = {} }
    entry.started = nil
    return updateRedraws()
  end

  local generation, finished = entry.generation, false
  local custom = config.values.catalog.clients[dbClient.name]
  entry.started = vim.uv.hrtime()
  updateRedraws()

  local function current()
    return not finished and entry.generation == generation
  end

  vim.defer_fn(mainloop.wrap(function()
    if current() then
      vim.notify("db-query: reading the catalog of " .. key)
    end
  end), NOTICE_AFTER_MS)

  -- A catalog function of the user's own may call done from anywhere.
  ---@type fun(catalog: dbquery.Catalog|nil, err: string|nil)
  local done = mainloop.wrap(function(catalog, err)
    if not current() then
      return
    end
    finished = true
    stop(entry)
    local seconds = (vim.uv.hrtime() - entry.started) / 1e9
    entry.started = nil
    updateRedraws()
    local problem = err or (catalog == nil and "no catalog was returned") or shape.problem(catalog)
    if problem then
      return vim.notify(
        string.format("db-query: could not read the catalog of %s, :DBRefreshCatalog retries: %s", key, problem),
        vim.log.levels.ERROR
      )
    end
    entry.catalog = catalog
    vim.notify(string.format("db-query: read the catalog of %s in %.1fs", key, seconds))
    saved.save(key, catalog)
  end)

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
    client = dbClient.name,
    connection = resolved,
    timeout = not custom and config.values.catalog.timeout or nil,
    query = function(statement, opts, callback)
      if not current() then
        return
      end
      local process = client.read({
        connection = resolved,
        statement = statement,
        timeout = (opts or {}).timeout,
        readonly = true,
      }, function(output, err)
        if current() then
          guarded(callback, output, err)
        end
      end)
      if process then
        table.insert(entry.processes, process)
      end
    end,
  }

  guarded(custom or dbClient.catalog, request, done)
end

--- Stops the read of `resolved`'s catalog under way, keeping the catalog from
--- before it.
---@param resolved string Resolved url.
function M.cancel(resolved)
  local dbClient = client.of(resolved)
  local key = dbClient and keyOf(resolved, dbClient)
  local entry = key and entries[key]
  if not (entry and entry.started) then
    return vim.notify("db-query: no catalog read is running for this database", vim.log.levels.WARN)
  end
  stop(entry)
  entry.generation = entry.generation + 1
  entry.started = nil
  updateRedraws()
  vim.notify("db-query: cancelled the read of the catalog of " .. key)
end

--- Returns the seconds a read of a connection's catalog has been running, or
--- nil when none is. Calls `resolveUrl` only while some read is running,
--- because a statusline asks on every redraw.
---@param resolveUrl fun(): string|nil Returns the resolved url.
---@return number|nil
function M.reading(resolveUrl)
  if not anyReading() then
    return nil
  end
  local resolved = resolveUrl()
  local dbClient = resolved and client.of(resolved)
  local entry = dbClient and entries[keyOf(resolved, dbClient)]
  return entry and entry.started and (vim.uv.hrtime() - entry.started) / 1e9 or nil
end

--- Returns the last catalog read for `resolved`, or nil when none has been.
--- Starts the first read, and never starts another: a failed read waits for
--- `refresh`, so an unreachable database is not asked again on every call.
---@param resolved string Resolved url.
---@return dbquery.Catalog|nil
function M.get(resolved)
  local dbClient = client.of(resolved)
  if not dbClient then
    return nil
  end
  local key = keyOf(resolved, dbClient)
  if not entries[key] then
    M.refresh(resolved)
  end
  return entries[key] and entries[key].catalog
end

return M
