--[[
A language server that runs inside nvim, giving any completion engine the
columns, tables, and functions of a sql buffer's database, with hover and
signature help.

- `attach` starts the server for a buffer, or attaches the running one.

nvim calls the server's `request` in the requester's own call stack, which
during completion is under textlock, and records the request as pending only
after `request` returns. So `request` reads the buffer at once and answers
from a later pass of the main loop, never inside the call.
]]

local complete = require("db-query.lsp.complete")
local context = require("db-query.sql.context")
local document = require("db-query.lsp.document")
local hover = require("db-query.lsp.hover")
local main = require("db-query.main")
local signature = require("db-query.lsp.signature")

local M = {}

local NAME = "db-query"
local ErrorCodes = vim.lsp.protocol.ErrorCodes

---@alias dbquery.LspHandler fun(opened: dbquery.Opened, params: table, snippets: boolean): any

--- Returns true when the request was made by typing a quote that closed what
--- an earlier quote opened. The quote that opens a string asks for the values
--- it may hold; the quote that ends one asks for nothing.
---@param opened dbquery.Opened
---@param at dbquery.CursorContext
---@param params table
---@return boolean
local function closingQuote(opened, at, params)
  local trigger = params.context
  if trigger == nil or trigger.triggerKind ~= vim.lsp.protocol.CompletionTriggerKind.TriggerCharacter then
    return false
  end
  local lex = opened.document.dialect.lex
  local character = trigger.triggerCharacter
  if lex.strings[character] ~= nil then
    return at.kind ~= "literal"
  end
  if lex.identifiers[character] ~= nil then
    -- A quoted name still being typed holds no closing quote yet.
    return #at.word.text > 1 and at.word.text:sub(-1) == character
  end
  return false
end

---@type table<string, dbquery.LspHandler>
local HANDLERS = {
  ["textDocument/completion"] = function(opened, params, snippets)
    local cursor = document.offset(opened.lines, params.position)
    local at = context.at(opened.document, cursor)
    if closingQuote(opened, at, params) then
      return { isIncomplete = false, items = {} }
    end
    return { isIncomplete = false, items = complete.items(opened, at, cursor, snippets) }
  end,
  ["textDocument/signatureHelp"] = function(opened, params)
    return signature.help(opened, context.at(opened.document, document.offset(opened.lines, params.position)))
  end,
  ["textDocument/hover"] = function(opened, params)
    -- A hover position is the start of the character under the cursor, and
    -- the word it belongs to is the one that character is in.
    return hover.hover(opened, context.at(opened.document, document.offset(opened.lines, params.position) + 1))
  end,
}

---@param dispatchers vim.lsp.rpc.Dispatchers
---@return vim.lsp.rpc.PublicClient
local function server(dispatchers)
  local closing, lastId, snippets = false, 0, false
  --- Requests not answered yet, mapped to whether the client cancelled them.
  ---@type table<integer, boolean>
  local pending = {}

  local function close()
    if not closing then
      closing = true
      dispatchers.on_exit(0, 15)
    end
  end

  --- Answers request `id` once, on the main loop, with what `answer` returns.
  --- A cancelled request is only marked answered, as nvim's own rpc client
  --- does, so the requester never hears of it.
  ---@param id integer
  ---@param callback fun(err: lsp.ResponseError|nil, result: any)
  ---@param replied fun(id: integer)|nil
  ---@param answer fun(): any
  local function respond(id, callback, replied, answer)
    pending[id] = false
    vim.schedule(function()
      main.run(function()
        local cancelled = pending[id]
        pending[id] = nil
        local ok, result = true, nil
        if not cancelled then
          ok, result = pcall(answer)
          if not ok and not (type(result) == "table" and result.code) then
            result = { code = ErrorCodes.InternalError, message = tostring(result) }
          end
        end
        if replied then
          replied(id)
        end
        if cancelled then
          return
        end
        if ok then
          callback(nil, result)
        else
          callback(result, nil)
        end
      end)
    end)
  end

  return {
    request = function(method, params, callback, replied)
      if closing then
        return false, nil
      end
      lastId = lastId + 1
      local id = lastId
      if method == "initialize" then
        snippets = vim.tbl_get(params, "capabilities", "textDocument", "completion", "completionItem", "snippetSupport") == true
        respond(id, callback, replied, function()
          return {
            serverInfo = { name = NAME },
            capabilities = {
              positionEncoding = "utf-8",
              completionProvider = { triggerCharacters = { ".", "(", "'", '"' } },
              signatureHelpProvider = { triggerCharacters = { "(", "," } },
              hoverProvider = true,
            },
          }
        end)
      elseif HANDLERS[method] then
        local captured = document.capture(params.textDocument.uri)
        respond(id, callback, replied, function()
          return captured and HANDLERS[method](document.open(captured), params, snippets) or nil
        end)
      elseif method == "shutdown" then
        respond(id, callback, replied, function()
          return nil
        end)
      else
        respond(id, callback, replied, function()
          error({ code = ErrorCodes.MethodNotFound, message = method })
        end)
      end
      return true, id
    end,
    notify = function(method, params)
      if method == "$/cancelRequest" and pending[params.id] ~= nil then
        pending[params.id] = true
      elseif method == "exit" then
        close()
      end
      return true
    end,
    is_closing = function()
      return closing
    end,
    terminate = close,
  }
end

--- Attaches the server to `buf`, starting it if it is not running.
---@param buf integer
function M.attach(buf)
  vim.lsp.start({ name = NAME, cmd = server }, { bufnr = buf })
end

return M
