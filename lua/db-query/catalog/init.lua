--[[
The catalog of each database, read in the background and saved to disk for the
next session.

- `get` returns what is known of a connection's catalog, and starts the first
  read of it. The first call for a database loads what the last session saved.
- `refresh` reads it again, replacing a read still under way.
- `cancel` stops the read under way and keeps the catalog from before it.
- `reading` says how long a read has been running, for a statusline.

Nothing waits on a read. Until one finishes, `get` returns the catalog from
before it, or nil.

Each client file holds a built-in `catalog` function. The `catalog.clients`
setting replaces it for the clients it names.
]]

local client = require("db-query.client")
local config = require("db-query.config")
local Indicator = require("db-query.indicator")
local main = require("db-query.main")
local output = require("db-query.output")
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
---@field started integer|nil hrtime the read under way started, nil when none is.

---@type table<string, dbquery.CatalogEntry>
local entries = {}

local NOTICE_AFTER = 2000

--- Redraws winbars and statuslines while any read runs, so `status` spins.
---@type uv.uv_timer_t|nil
local ticker = nil

---@return boolean
local function reading()
  for _, entry in pairs(entries) do
    if entry.started then
      return true
    end
  end
  return false
end

--- Starts the redraw timer when a read is under way, and stops it when none is.
local function tick()
  if reading() and not ticker then
    ticker = vim.uv.new_timer()
    ticker:start(Indicator.FRAME_TIME, Indicator.FRAME_TIME, main.frame(function()
      vim.api.nvim__redraw({ statusline = true, winbar = true })
    end))
  elseif ticker and not reading() then
    ticker:stop()
    ticker:close()
    ticker = nil
    vim.api.nvim__redraw({ statusline = true, winbar = true })
  end
end

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

--- The version of `dbquery.Catalog` a saved file holds. Raise it with every
--- change to the shape, and add the step from the old version to `UPGRADES`.
local VERSION = 1

--- Steps a saved catalog from the version it is keyed by to the next one.
--- Leave a version out, or return nil from its step, when the change needs
--- data only a fresh read has, and the saved file is discarded.
---@type table<integer, fun(catalog: table): table|nil>
local UPGRADES = {}

---@class dbquery.SavedCatalog
---@field version integer
---@field catalog dbquery.Catalog

--- Returns the catalog saved for `key` by an earlier session, upgraded to
--- `VERSION`, or nil when there is none or it cannot be used.
---@param key string
---@return dbquery.Catalog|nil
local function load(key)
  local file = io.open(output.catalog(key), "r")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  local ok, saved = pcall(vim.json.decode, text, { luanil = { object = true } })
  if not (ok and type(saved) == "table" and type(saved.version) == "number" and saved.version <= VERSION) then
    return nil
  end
  local catalog, version = saved.catalog, saved.version
  while catalog and version < VERSION do
    local upgrade = UPGRADES[version]
    catalog = upgrade and upgrade(catalog)
    version = version + 1
  end
  if not catalog or shape.problem(catalog) then
    return nil
  end
  return catalog
end

--- Saves `catalog` for `key`, through a file of this nvim's own renamed into
--- place, so two nvims saving at once never leave a mixed file.
---@param key string
---@param catalog dbquery.Catalog
local function save(key, catalog)
  local path = output.catalog(key)
  local function failed(err)
    vim.notify("db-query: cannot save the catalog to " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
  end

  ---@type dbquery.SavedCatalog
  local saved = { version = VERSION, catalog = catalog }
  local encoded, text = pcall(vim.json.encode, saved)
  if not encoded then
    return failed(text)
  end
  local partial = path .. "." .. vim.uv.os_getpid()
  local file, err = io.open(partial, "w")
  if not file then
    return failed(err)
  end
  local wrote, writeErr = file:write(text)
  local closed, closeErr = file:close()
  local renamed, renameErr = nil, writeErr or closeErr
  if wrote and closed then
    renamed, renameErr = vim.uv.fs_rename(partial, path)
  end
  if not renamed then
    os.remove(partial)
    failed(renameErr)
  end
end

--- Returns the entry for `key`, creating it with the catalog an earlier session
--- saved.
---@param key string
---@return dbquery.CatalogEntry
local function entryOf(key)
  if not entries[key] then
    entries[key] = { catalog = load(key), generation = 0, processes = {} }
  end
  return entries[key]
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
  local entry = entryOf(key)
  stop(entry)
  entry.generation = entry.generation + 1

  -- Opening a missing file read-only fails, and until something creates it the
  -- database holds nothing.
  local file = found.embedded and url.filePath(connection) or ""
  if file ~= "" and not vim.uv.fs_stat(file) then
    entry.catalog = { searchPath = {}, relations = {}, functions = {}, types = {} }
    entry.started = nil
    return tick()
  end

  local generation, finished = entry.generation, false
  local custom = config.values.catalog.clients[found.name]
  entry.started = vim.uv.hrtime()
  tick()

  local function current()
    return not finished and entry.generation == generation
  end

  vim.defer_fn(main.wrap(function()
    if current() then
      vim.notify("db-query: reading the catalog of " .. key)
    end
  end), NOTICE_AFTER)

  -- A catalog function of the user's own may call done from anywhere.
  ---@type fun(catalog: dbquery.Catalog|nil, err: string|nil)
  local done = main.wrap(function(catalog, err)
    if not current() then
      return
    end
    finished = true
    stop(entry)
    local seconds = (vim.uv.hrtime() - entry.started) / 1e9
    entry.started = nil
    tick()
    local problem = err or (catalog == nil and "no catalog was returned") or shape.problem(catalog)
    if problem then
      return vim.notify(
        string.format("db-query: could not read the catalog of %s, :DBRefreshCatalog retries: %s", key, problem),
        vim.log.levels.ERROR
      )
    end
    entry.catalog = catalog
    vim.notify(string.format("db-query: read the catalog of %s in %.1fs", key, seconds))
    save(key, catalog)
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

--- Stops the read of `connection`'s catalog under way, keeping the catalog from
--- before it.
---@param connection string Resolved url.
function M.cancel(connection)
  local found = client.of(connection)
  local key = found and keyOf(connection, found)
  local entry = key and entries[key]
  if not (entry and entry.started) then
    return vim.notify("db-query: no catalog read is running for this database", vim.log.levels.WARN)
  end
  stop(entry)
  entry.generation = entry.generation + 1
  entry.started = nil
  tick()
  vim.notify("db-query: cancelled the read of the catalog of " .. key)
end

--- Returns the seconds a read of `connection`'s catalog has been running, or
--- nil when none is. Resolves nothing unless some read is running, because a
--- statusline asks on every redraw.
---@param connection fun(): string|nil Returns the resolved url.
---@return number|nil
function M.reading(connection)
  if not reading() then
    return nil
  end
  local resolved = connection()
  local found = resolved and client.of(resolved)
  local entry = found and entries[keyOf(resolved, found)]
  return entry and entry.started and (vim.uv.hrtime() - entry.started) / 1e9 or nil
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
