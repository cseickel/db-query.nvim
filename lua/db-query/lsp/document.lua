--[[
The buffer a request is about, read when the request arrives.

- `capture` reads the buffer's lines and connection. It only reads, so it runs
  under textlock, where completion requests arrive.
- `open` resolves the connection to its dialect and catalog, on the main loop.
- `offset` and `position` convert between LSP positions and byte offsets.
]]

local catalog = require("db-query.catalog")
local client = require("db-query.client")
local dadbod = require("db-query.dadbod")
local lex = require("db-query.sql.lex")

local M = {}

---@class dbquery.Captured
---@field buf integer
---@field lines string[]
---@field written string|nil The buffer's `b:db`.
---@field filetype string

---@class dbquery.Opened : dbquery.Captured
---@field document dbquery.Document
---@field catalog dbquery.Catalog|nil Nil until the connection's catalog has been read.

--- Returns the current buffer's lines and connection when `uri` names it, and
--- nil otherwise. An unnamed buffer's uri is `file://` whichever buffer it is,
--- so a request about one is taken to be about the current buffer, which is
--- the buffer every completion, hover, and signature request is made from.
---@param uri string
---@return dbquery.Captured|nil
function M.capture(uri)
  local buf = vim.api.nvim_get_current_buf()
  if vim.uri_from_bufnr(buf) ~= uri then
    return nil
  end
  local written = vim.b[buf].db
  return {
    buf = buf,
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    written = type(written) == "string" and written or nil,
    filetype = vim.bo[buf].filetype,
  }
end

--- Returns `captured` with its text lexed by the connection's dialect, and the
--- connection's catalog. A buffer with no connection, or one whose client is
--- unknown, reads by the standard dialect, or mysql's for a mysql buffer.
---@param captured dbquery.Captured
---@return dbquery.Opened
function M.open(captured)
  local resolved = dadbod.resolve(captured.written)
  local found = resolved and client.of(resolved)
  local dialect = found and found.dialect
    or require("db-query.sql.dialect." .. (captured.filetype == "mysql" and "mysql" or "standard"))
  local text = table.concat(captured.lines, "\n")
  ---@type dbquery.Opened
  return {
    buf = captured.buf,
    lines = captured.lines,
    written = captured.written,
    filetype = captured.filetype,
    document = { dialect = dialect, text = text, tokens = lex.tokens(dialect, text) },
    catalog = found and catalog.get(resolved) or nil,
  }
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
