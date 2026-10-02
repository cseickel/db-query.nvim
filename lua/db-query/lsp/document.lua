--[[
Reads the buffer a request is about, as text addressed by LSP positions.
]]

local catalog = require("db-query.catalog")
local client = require("db-query.client")
local dadbod = require("db-query.connection.dadbod")
local lex = require("db-query.sql.lex")

local M = {}

---@class dbquery.Captured
---@field buf integer
---@field lines string[]
---@field db string|nil The buffer's `b:db`.
---@field filetype string

---@class dbquery.Opened : dbquery.Captured
---@field document dbquery.Document
---@field catalog dbquery.Catalog|nil Nil until the connection's catalog has been read.

--- Returns the buffer `uri` names. An unnamed buffer's uri is `file://`
--- whichever buffer it is, so a request about one is taken to be about the
--- current buffer, which is the buffer the editor's own requests are made from.
---@param uri string
---@return integer|nil
local function bufferAt(uri)
  local current = vim.api.nvim_get_current_buf()
  if vim.uri_from_bufnr(current) == uri then
    return current
  end
  return vim.iter(vim.api.nvim_list_bufs()):find(function(buf)
    return vim.api.nvim_buf_get_name(buf) ~= "" and vim.uri_from_bufnr(buf) == uri
  end)
end

--- Returns the lines and connection of the buffer `uri` names, or nil when no
--- buffer has that uri. It only reads, so it runs under textlock, where
--- completion requests arrive.
---@param uri string
---@return dbquery.Captured|nil
function M.capture(uri)
  local buf = bufferAt(uri)
  if not buf then
    return nil
  end
  local db = vim.b[buf].db
  return {
    buf = buf,
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    db = type(db) == "string" and db or nil,
    filetype = vim.bo[buf].filetype,
  }
end

--- Returns `captured` with its text lexed by the connection's dialect, and the
--- connection's catalog. A buffer with no connection, or one whose client is
--- unknown, reads by the standard dialect, or mysql's for a mysql buffer.
---@param captured dbquery.Captured
---@return dbquery.Opened
function M.open(captured)
  local url = dadbod.resolve(captured.db)
  local dbClient = url and client.of(url)
  local dialect = dbClient and dbClient.dialect
    or require("db-query.sql.dialect." .. (captured.filetype == "mysql" and "mysql" or "standard"))
  return vim.tbl_extend("force", captured, {
    document = lex.document(dialect, table.concat(captured.lines, "\n")),
    catalog = dbClient and catalog.get(url) or nil,
  })
end

--- Returns the byte offset in the joined lines that an LSP position, counted
--- in bytes, stands before, counting from 1.
---@param lines string[]
---@param position lsp.Position
---@return integer
function M.offset(lines, position)
  local offset = 0
  for index = 1, math.min(position.line, #lines) do
    offset = offset + #lines[index] + 1
  end
  local line = lines[position.line + 1] or ""
  return offset + math.min(position.character, #line) + 1
end

--- Returns the LSP position, counted in bytes, of the byte offset `offset`.
---@param lines string[]
---@param offset integer Counting from 1.
---@return lsp.Position
function M.position(lines, offset)
  local remaining = offset - 1
  for index, line in ipairs(lines) do
    if remaining <= #line then
      return { line = index - 1, character = remaining }
    end
    remaining = remaining - #line - 1
  end
  return { line = math.max(#lines - 1, 0), character = #(lines[#lines] or "") }
end

return M
