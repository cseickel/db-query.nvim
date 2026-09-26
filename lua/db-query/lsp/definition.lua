--[[
Goto definition and references for the name under the cursor.

Definition opens the DDL of the table, view, or function the name refers to,
or of a column's table. References opens the DDL of each relation and routine
that depends on it. The DDL is read from the database into files in this
nvim's cache, and each file's buffer runs against the same connection.
]]

local client = require("db-query.client")
local config = require("db-query.config")
local dadbod = require("db-query.connection.dadbod")
local files = require("db-query.query.files")
local lex = require("db-query.sql.lex")
local names = require("db-query.lsp.names")
local query = require("db-query.client.query")
local target = require("db-query.lsp.target")

local M = {}

--- How many DDL reads goto references runs at once. Each read is a client
--- process and, on a server, a connection of its own.
local READS_AT_ONCE = 4

---@class dbquery.DefinitionSource
---@field opened dbquery.Opened
---@field url string
---@field dbClient dbquery.Client
---@field request dbquery.CatalogRequest

--- Returns the connection, client, and request that read DDL for `opened`, or
--- nil when its buffer has no connection a client runs.
---@param opened dbquery.Opened
---@param reply dbquery.LspReply
---@return dbquery.DefinitionSource|nil
local function sourceOf(opened, reply)
  local url = dadbod.resolve(opened.db)
  local dbClient = url and client.of(url)
  if not (url and dbClient) then
    return nil
  end
  return {
    opened = opened,
    url = url,
    dbClient = dbClient,
    request = {
      client = dbClient.name,
      connection = url,
      timeout = config.values.catalog.timeout,
      query = function(statement, opts, callback)
        client.read({
          client = dbClient,
          connection = url,
          statement = statement,
          timeout = (opts or {}).timeout,
          readonly = true,
        }, function(text, err)
          -- The callback runs once the query finishes, outside the request
          -- that started it, so an error it throws is sent as the reply.
          local ok, callbackErr = pcall(callback, text, err)
          if not ok then
            reply(callbackErr, nil)
          end
        end)
      end,
    },
  }
end

--- Writes `text` to `path` and to its buffer if loaded, sets that buffer's
--- connection to `opened`'s, and returns the file's uri and lines. Throws when
--- the file cannot be written.
---@param path string
---@param text string
---@param opened dbquery.Opened
---@return string uri
---@return string[] lines
local function writeDefinition(path, text, opened)
  local lines = vim.split((text:gsub("\n$", "")), "\n", { plain = true })
  if vim.fn.writefile(lines, path) ~= 0 then
    error("cannot write " .. path, 0)
  end
  local uri = vim.uri_from_fname(path)
  local buf = vim.uri_to_bufnr(uri)
  if vim.api.nvim_buf_is_loaded(buf) then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modified = false
  end
  vim.b[buf].db = opened.db
  vim.b[buf].db_name = vim.b[opened.buf].db_name
  return uri, lines
end

--- Reads the DDL of `named` into its file and calls `done` with the file's
--- location: the first line naming `mentioned`, or the first line.
---@param source dbquery.DefinitionSource
---@param named dbquery.Target
---@param mentioned string|nil
---@param done fun(location: lsp.Location|nil, err: string|nil)
local function locationOf(source, named, mentioned, done)
  source.dbClient.definition(source.request, named, function(text, err)
    if not text then
      return done(nil, err)
    end
    local path = files.definition(source.url, names.qualifiedParts(query.object(named)))
    local ok, uriOrErr, lines = pcall(writeDefinition, path, text, source.opened)
    if not ok then
      return done(nil, uriOrErr)
    end
    local uri = uriOrErr
    local line = 0
    for index, content in ipairs(mentioned and lines or {}) do
      if lex.mentions(source.opened.document.dialect, content, mentioned) then
        line = index - 1
        break
      end
    end
    local start = { line = line, character = 0 }
    done({ uri = uri, range = { start = start, ["end"] = start } })
  end)
end

---@param err string|nil
---@return lsp.ResponseError
local function requestFailed(err)
  return { code = vim.lsp.protocol.ErrorCodes.RequestFailed, message = "db-query: " .. tostring(err) }
end

--- Replies with the location of the DDL of what the word in `context` names,
--- once the database has returned it, or with nil when the word names nothing
--- the catalog holds.
---@param opened dbquery.Opened
---@param context dbquery.CursorContext
---@param reply dbquery.LspReply
function M.locate(opened, context, reply)
  local named = target.at(opened, context)
  local source = named and sourceOf(opened, reply)
  if not (named and source) then
    return reply(nil, nil)
  end
  locationOf(source, named, nil, function(location, err)
    if not location then
      return reply(requestFailed(err), nil)
    end
    reply(nil, location)
  end)
end

--- Returns the catalog object `reference` names, or nil when the catalog does
--- not hold it, such as a partition, or one made since the catalog was read.
---@param catalog dbquery.Catalog
---@param reference dbquery.Reference
---@return dbquery.Target|nil
local function targetOf(catalog, reference)
  local function same(item)
    return item.name == reference.name and item.schema == reference.schema
      and (reference.database == nil or item.database == reference.database)
  end
  if reference.routine then
    local functions = vim.tbl_filter(same, catalog.functions)
    return #functions > 0 and { kind = "functions", functions = functions } or nil
  end
  local relation = vim.iter(catalog.relations):find(same)
  return relation and { kind = "relation", relation = relation } or nil
end

--- Replies with the locations of the DDL of every relation and routine that
--- depends on what the word in `context` names, each at the first line naming
--- it, and of its own DDL first when `declaration` is set.
---@param opened dbquery.Opened
---@param context dbquery.CursorContext
---@param declaration boolean
---@param reply dbquery.LspReply
function M.references(opened, context, declaration, reply)
  local named = target.at(opened, context)
  local source = named and sourceOf(opened, reply)
  local catalog = opened.catalog
  if not (named and source and catalog) then
    return reply(nil, nil)
  end
  local mentioned = query.object(named).name

  source.dbClient.references(source.request, named, function(references, err)
    if not references then
      return reply(requestFailed(err), nil)
    end
    local targets = declaration and { named } or {}
    for _, reference in ipairs(references) do
      local referring = targetOf(catalog, reference)
      if referring then
        table.insert(targets, referring)
      end
    end
    if #targets == 0 then
      return reply(nil, {})
    end

    local locations, started, pending, firstErr = {}, 0, #targets, nil
    local function startNext()
      if started == #targets then
        return
      end
      started = started + 1
      local index = started
      locationOf(source, targets[index], mentioned, function(location, locationErr)
        locations[index] = location or false
        firstErr = firstErr or locationErr
        pending = pending - 1
        if pending > 0 then
          return startNext()
        end
        local answered = vim.tbl_filter(function(item)
          return item ~= false
        end, locations)
        if #answered == 0 then
          return reply(requestFailed(firstErr), nil)
        end
        reply(nil, answered)
      end)
    end
    for _ = 1, math.min(READS_AT_ONCE, #targets) do
      startNext()
    end
  end)
end

return M
