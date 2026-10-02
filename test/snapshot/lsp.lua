--[[
Sends requests to the plugin's language server in a sql buffer and writes each
answer out as text.
]]

local M = {}

local FUNCTION_KIND = vim.lsp.protocol.CompletionItemKind.Function

---@param value any
---@return string
local function oneLine(value)
  return vim.inspect(value, { newline = " ", indent = "" })
end

--- Returns the contents of `path`, or a line saying it is missing.
---@param path string
---@return string
function M.readFile(path)
  local file = io.open(path, "r")
  if not file then
    return "<missing " .. path .. ">"
  end
  local text = file:read("*a")
  file:close()
  return text
end

---@param buf integer
local function focus(buf)
  local win = vim.fn.win_findbuf(buf)[1]
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.api.nvim_set_current_buf(buf)
  end
end
M.focus = focus

--- Opens `path` as a sql buffer connected to `url`, and returns it once the
--- language server has attached.
---@param path string
---@param url string
---@return integer
function M.open(path, url)
  vim.fn.writefile({ "" }, path)
  vim.cmd("silent only")
  vim.cmd("silent edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].db = url
  vim.bo[buf].filetype = "sql"
  local attached = vim.wait(5000, function()
    local client = vim.lsp.get_clients({ bufnr = buf, name = "db-query" })[1]
    return client ~= nil and client.initialized ~= false and client.server_capabilities ~= nil
  end, 20)
  if not attached then
    error("the language server did not attach to " .. path)
  end
  return buf
end

--- Returns the lines of `text` with its `|` removed, and the LSP position the
--- `|` stood at.
---@param text string
---@return string[] lines
---@return lsp.Position position
local function unmark(text)
  local marker = assert(text:find("|", 1, true), "a case needs a | marker: " .. text)
  local clean = text:sub(1, marker - 1) .. text:sub(marker + 1)
  local before = clean:sub(1, marker - 1)
  local row = select(2, before:gsub("\n", ""))
  local lastNewline = before:match(".*()\n")
  local col = lastNewline and (#before - lastNewline) or #before
  return vim.split(clean, "\n"), { line = row, character = col }
end

--- Puts `text` in `buf` with the cursor at `|`, and returns the LSP position
--- of the cursor.
---@param buf integer
---@param text string
---@return lsp.Position
local function place(buf, text)
  local lines, position = unmark(text)
  focus(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { position.line + 1, position.character })
  return position
end

--- Sends `method` about `buf` with `params`, and returns the result, or a
--- table naming the error.
---@param buf integer
---@param method string
---@param params table The request's params, less `textDocument`.
---@return any
local function send(buf, method, params)
  params = vim.tbl_extend("force", { textDocument = { uri = vim.uri_from_bufnr(buf) } }, params)
  local responses, err = vim.lsp.buf_request_sync(buf, method, params, 15000)
  if not responses then
    return { harness_error = tostring(err) }
  end
  for _, response in pairs(responses) do
    if response.err then
      return { lsp_error = response.err.message }
    end
    return response.result
  end
  return { harness_error = "no response" }
end

--- Sends `method` for the cursor at `|` in `text`, and returns the result, or
--- a table naming the error.
---@param buf integer
---@param method string
---@param text string
---@param extra table|nil Merged into the request's params.
---@return any
local function request(buf, method, text, extra)
  return send(buf, method, vim.tbl_extend("force", { position = place(buf, text) }, extra or {}))
end

--- Returns the completion items at `|` in `text`, one per line in sort order.
--- A function item is kept only when `functions` names it.
---@param buf integer
---@param text string
---@param trigger string|nil The character the completion was triggered by.
---@param functions string[]
---@return string
function M.complete(buf, text, trigger, functions)
  local context = trigger and { triggerKind = 2, triggerCharacter = trigger } or { triggerKind = 1 }
  local result = request(buf, "textDocument/completion", text, { context = context })
  if type(result) ~= "table" or result.items == nil then
    return oneLine(result)
  end
  local items = vim.tbl_filter(function(item)
    return item.kind ~= FUNCTION_KIND or vim.tbl_contains(functions, item.label)
  end, result.items)
  table.sort(items, function(a, b)
    if a.sortText ~= b.sortText then
      return a.sortText < b.sortText
    end
    return a.label < b.label
  end)
  local lines = { "isIncomplete=" .. tostring(result.isIncomplete) }
  for _, item in ipairs(items) do
    lines[#lines + 1] = oneLine({
      label = item.label,
      kind = item.kind,
      detail = item.detail,
      labelDetails = item.labelDetails,
      filterText = item.filterText,
      newText = item.textEdit and item.textEdit.newText,
      range = item.textEdit and item.textEdit.range,
      insertTextFormat = item.insertTextFormat,
    })
  end
  return table.concat(lines, "\n")
end

--- Returns the text of a hover result.
---@param result any
---@return string
local function hoverText(result)
  if type(result) == "table" and result.contents then
    return result.contents.value or oneLine(result.contents)
  end
  return oneLine(result)
end

--- Returns the hover text at `|` in `text`.
---@param buf integer
---@param text string
---@return string
function M.hover(buf, text)
  return hoverText(request(buf, "textDocument/hover", text))
end

--- Returns the hover text at `|` in `text`, asked about a hidden buffer named
--- `name` while `buf` stays current, the way a file tree asks about one of its
--- nodes.
---@param buf integer
---@param name string
---@param text string
---@return string
function M.hoverHidden(buf, name, text)
  focus(buf)
  local hidden = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(hidden, name)
  vim.b[hidden].db = vim.b[buf].db
  vim.bo[hidden].filetype = "sql"
  local lines, position = unmark(text)
  vim.api.nvim_buf_set_lines(hidden, 0, -1, false, lines)
  vim.wait(5000, function()
    return #vim.lsp.get_clients({ bufnr = hidden, name = "db-query" }) > 0
  end, 20)
  local hovered = hoverText(send(hidden, "textDocument/hover", { position = position }))
  vim.api.nvim_buf_delete(hidden, { force = true })
  return hovered
end

--- Returns the signature help at `|` in `text`.
---@param buf integer
---@param text string
---@return string
function M.signature(buf, text)
  return vim.inspect(request(buf, "textDocument/signatureHelp", text))
end

--- Returns each location in `result` with the line it points at and the whole
--- file, sorted by path and line.
---@param result any
---@return string
local function locations(result)
  if type(result) ~= "table" or result.lsp_error or result.harness_error then
    return oneLine(result)
  end
  if result.uri then
    result = { result }
  end
  local entries = vim.tbl_map(function(location)
    return { path = vim.uri_to_fname(location.uri), range = location.range }
  end, result)
  table.sort(entries, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.range.start.line < b.range.start.line
  end)
  local lines = { "count=" .. #entries }
  for _, entry in ipairs(entries) do
    local contents = M.readFile(entry.path)
    vim.list_extend(lines, {
      "== " .. entry.path .. " " .. oneLine(entry.range),
      "line: " .. tostring(vim.split(contents, "\n")[entry.range.start.line + 1]),
      contents,
    })
  end
  return table.concat(lines, "\n")
end

--- Returns the definition at `|` in `text`.
---@param buf integer
---@param text string
---@return string
function M.definition(buf, text)
  return locations(request(buf, "textDocument/definition", text))
end

--- Returns the references at `|` in `text`.
---@param buf integer
---@param text string
---@param includeDeclaration boolean
---@return string
function M.references(buf, text, includeDeclaration)
  return locations(request(buf, "textDocument/references", text, {
    context = { includeDeclaration = includeDeclaration },
  }))
end

return M
