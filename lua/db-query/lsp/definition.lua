--[[
Goto definition for the name under the cursor: the DDL of the table, view, or
function it names, or of a column's table, read from the database into a file
in this nvim's cache. The buffer of that file runs against the same connection.
]]

local client = require("db-query.client")
local config = require("db-query.config")
local dadbod = require("db-query.dadbod")
local output = require("db-query.output")
local target = require("db-query.lsp.target")

local M = {}

---@param found dbquery.Target
---@return string[]
local function qualifiedName(found)
  local named = found.kind == "functions" and found.functions[1] or found.relation
  local parts = {}
  for _, part in ipairs({ named.database or false, named.schema or false, named.name }) do
    if part then
      table.insert(parts, part)
    end
  end
  return parts
end

--- Writes `ddl` to `path`, and over its buffer when that is loaded, gives the
--- buffer the connection of `opened`'s, and returns the file's uri.
---@param path string
---@param ddl string
---@param opened dbquery.Opened
---@return string
local function written(path, ddl, opened)
  local lines = vim.split((ddl:gsub("\n$", "")), "\n", { plain = true })
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
  return uri
end

--- Replies with the location of the DDL of what the word in `context` names,
--- once the database has returned it, or with nil when the word names nothing
--- the catalog holds.
---@param opened dbquery.Opened
---@param context dbquery.CursorContext
---@param reply dbquery.LspReply
function M.locate(opened, context, reply)
  local found = target.at(opened, context)
  local resolved = found and dadbod.resolve(opened.written)
  local owner = resolved and client.of(resolved)
  if not (found and resolved and owner) then
    return reply(nil, nil)
  end

  --- Calls `fn`, replying with its error when it throws, since it runs after
  --- the query finishes, outside the request that started it.
  local function guarded(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
      reply(err, nil)
    end
  end

  ---@type dbquery.CatalogRequest
  local request = {
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
        guarded(callback, text, err)
      end)
    end,
  }

  owner.definition(request, found, function(ddl, err)
    guarded(function()
      if not ddl then
        return reply({ code = vim.lsp.protocol.ErrorCodes.RequestFailed, message = "db-query: " .. tostring(err) }, nil)
      end
      local uri = written(output.definition(resolved, qualifiedName(found)), ddl, opened)
      local start = { line = 0, character = 0 }
      reply(nil, { uri = uri, range = { start = start, ["end"] = start } })
    end)
  end)
end

return M
