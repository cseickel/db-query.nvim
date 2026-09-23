--[[
Goto definition and references for the name under the cursor.

Definition opens the DDL of the table, view, or function the name refers to,
or of a column's table. References opens the DDL of each relation and routine
that depends on it. The DDL is read from the database into files in this
nvim's cache, and each file's buffer runs against the same connection.
]]

local client = require("db-query.client")
local config = require("db-query.config")
local dadbod = require("db-query.dadbod")
local ddl = require("db-query.client.definition")
local output = require("db-query.output")
local target = require("db-query.lsp.target")

local M = {}

--- How many DDL reads goto references runs at once.
local READS_AT_ONCE = 4

---@class dbquery.DefinitionSource
---@field opened dbquery.Opened
---@field resolved string
---@field owner dbquery.Client
---@field request dbquery.CatalogRequest
---@field reply dbquery.LspReply

---@param found dbquery.Target
---@return { database: string|nil, schema: string|nil, name: string }
local function namedBy(found)
  return found.kind == "functions" and found.functions[1] or found.relation
end

---@param found dbquery.Target
---@return string[]
local function qualifiedName(found)
  local named = namedBy(found)
  local parts = {}
  for _, part in ipairs({ named.database or false, named.schema or false, named.name }) do
    if part then
      table.insert(parts, part)
    end
  end
  return parts
end

--- Calls `fn`, replying with its error when it throws, since it runs after a
--- query finishes, outside the request that started it.
---@param reply dbquery.LspReply
---@param fn function
---@param ... any
local function guarded(reply, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    reply(err, nil)
  end
end

--- Returns the connection, client, and request that read DDL for `opened`, or
--- nil when the name under the cursor names nothing in the catalog.
---@param opened dbquery.Opened
---@param reply dbquery.LspReply
---@return dbquery.DefinitionSource|nil
local function sourceOf(opened, reply)
  local resolved = dadbod.resolve(opened.written)
  local owner = resolved and client.of(resolved)
  if not (resolved and owner) then
    return nil
  end
  return {
    opened = opened,
    resolved = resolved,
    owner = owner,
    reply = reply,
    request = {
      client = owner.name,
      connection = resolved,
      timeout = config.values.catalog.timeout,
      query = function(statement, opts, callback)
        client.read({
          connection = resolved,
          statement = statement,
          timeout = (opts or {}).timeout,
          readonly = true,
        }, function(text, err)
          guarded(reply, callback, text, err)
        end)
      end,
    },
  }
end

--- Writes `text` to `path`, and over its buffer when that is loaded, gives the
--- buffer the connection of `opened`'s, and returns the file's uri and lines.
---@param path string
---@param text string
---@param opened dbquery.Opened
---@return string uri
---@return string[] lines
local function written(path, text, opened)
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
  vim.b[buf].db = opened.written
  vim.b[buf].db_name = vim.b[opened.buf].db_name
  return uri, lines
end

--- Reads the DDL of `found` into its file and calls `done` with the file's
--- location: the first line naming `mentioned`, or the first line.
---@param source dbquery.DefinitionSource
---@param found dbquery.Target
---@param mentioned string|nil
---@param done fun(location: lsp.Location|nil, err: string|nil)
local function locationOf(source, found, mentioned, done)
  source.owner.definition(source.request, found, function(text, err)
    if not text then
      return done(nil, err)
    end
    local ok, uri, lines = pcall(written, output.definition(source.resolved, qualifiedName(found)), text, source.opened)
    if not ok then
      return done(nil, uri)
    end
    local line = 0
    for index, content in ipairs(mentioned and lines or {}) do
      if ddl.mentions(source.opened.document.dialect, content, mentioned) then
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
local function failed(err)
  return { code = vim.lsp.protocol.ErrorCodes.RequestFailed, message = "db-query: " .. tostring(err) }
end

--- Replies with the location of the DDL of what the word in `context` names,
--- once the database has returned it, or with nil when the word names nothing
--- the catalog holds.
---@param opened dbquery.Opened
---@param context dbquery.CursorContext
---@param reply dbquery.LspReply
function M.locate(opened, context, reply)
  local found = target.at(opened, context)
  local source = found and sourceOf(opened, reply)
  if not (found and source) then
    return reply(nil, nil)
  end
  locationOf(source, found, nil, function(location, err)
    if not location then
      return reply(failed(err), nil)
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
  local found = target.at(opened, context)
  local source = found and sourceOf(opened, reply)
  if not (found and source and opened.catalog) then
    return reply(nil, nil)
  end
  local mentioned = namedBy(found).name

  source.owner.references(source.request, found, function(references, err)
    if not references then
      return reply(failed(err), nil)
    end
    local targets = declaration and { found } or {}
    for _, reference in ipairs(references) do
      local referring = targetOf(opened.catalog, reference)
      if referring then
        table.insert(targets, referring)
      end
    end
    if #targets == 0 then
      return reply(nil, {})
    end

    local locations, started, pending, firstErr = {}, 0, #targets, nil
    local function finish()
      local answered = vim.tbl_filter(function(item)
        return item ~= false
      end, locations)
      if #answered == 0 then
        return reply(failed(firstErr), nil)
      end
      reply(nil, answered)
    end
    -- Each read is a client process and, on a server, a connection of its own.
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
        if pending == 0 then
          return finish()
        end
        startNext()
      end)
    end
    for _ = 1, math.min(READS_AT_ONCE, #targets) do
      startNext()
    end
  end)
end

return M
