--[[
A language server that runs inside nvim, giving any completion engine the
columns, tables, and functions of a sql buffer's database, with hover,
signature help, and the definition and references of a table or function.

nvim calls the server's `request` in the requester's own call stack, which
during completion is under textlock, and records the request as pending only
after `request` returns. So `request` reads the buffer at once and answers
from a later pass of the main loop, never inside the call.
]]

local complete = require("db-query.lsp.complete")
local context = require("db-query.sql.context")
local definition = require("db-query.lsp.definition")
local document = require("db-query.lsp.document")
local hover = require("db-query.lsp.hover")
local main = require("db-query.main")
local signature = require("db-query.lsp.signature")

local M = {}

local NAME = "db-query"
local ErrorCodes = vim.lsp.protocol.ErrorCodes

--- Answers a request, at once or once a query has finished. `err` is an LSP
--- error, or anything else thrown, which answers as an internal error.
---@alias dbquery.LspReply fun(err: any, result: any)

---@alias dbquery.LspHandler fun(opened: dbquery.Opened, params: table, reply: dbquery.LspReply, snippets: boolean)

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
  ["textDocument/completion"] = function(opened, params, reply, snippets)
    local cursor = document.offset(opened.lines, params.position)
    local at = context.at(opened.document, cursor)
    if closingQuote(opened, at, params) then
      return reply(nil, { isIncomplete = false, items = {} })
    end
    reply(nil, { isIncomplete = false, items = complete.items(opened, at, cursor, snippets) })
  end,
  ["textDocument/signatureHelp"] = function(opened, params, reply)
    reply(nil, signature.help(opened, context.at(opened.document, document.offset(opened.lines, params.position))))
  end,
  -- A hover, definition, or references position is the start of the character
  -- under the cursor, and the word it belongs to is the one that character is in.
  ["textDocument/hover"] = function(opened, params, reply)
    reply(nil, hover.hover(opened, context.at(opened.document, document.offset(opened.lines, params.position) + 1)))
  end,
  ["textDocument/definition"] = function(opened, params, reply)
    definition.locate(opened, context.at(opened.document, document.offset(opened.lines, params.position) + 1), reply)
  end,
  ["textDocument/references"] = function(opened, params, reply)
    local at = context.at(opened.document, document.offset(opened.lines, params.position) + 1)
    definition.references(opened, at, vim.tbl_get(params, "context", "includeDeclaration") == true, reply)
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

  --- Starts `answer` on the main loop, and answers request `id` with the first
  --- reply it makes, now or once a query has finished. A cancelled request is
  --- only marked answered, as nvim's own rpc client does, so the requester
  --- never hears of it.
  ---@param id integer
  ---@param callback fun(err: lsp.ResponseError|nil, result: any)
  ---@param replied fun(id: integer)|nil
  ---@param answer fun(reply: dbquery.LspReply)
  local function respond(id, callback, replied, answer)
    pending[id] = false
    local answered = false
    ---@type dbquery.LspReply
    local function reply(err, result)
      if answered then
        return
      end
      answered = true
      local cancelled = pending[id]
      pending[id] = nil
      if replied then
        replied(id)
      end
      if cancelled then
        return
      end
      if err == nil then
        return callback(nil, result)
      end
      if not (type(err) == "table" and err.code) then
        err = { code = ErrorCodes.InternalError, message = tostring(err) }
      end
      callback(err, nil)
    end
    vim.schedule(function()
      main.run(function()
        if pending[id] then
          return reply(nil, nil)
        end
        local ok, err = pcall(answer, reply)
        if not ok then
          reply(err, nil)
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
        respond(id, callback, replied, function(reply)
          reply(nil, {
            serverInfo = { name = NAME },
            capabilities = {
              positionEncoding = "utf-8",
              completionProvider = { triggerCharacters = { ".", "(", "'", '"' } },
              signatureHelpProvider = { triggerCharacters = { "(", "," } },
              hoverProvider = true,
              definitionProvider = true,
              referencesProvider = true,
            },
          })
        end)
      elseif HANDLERS[method] then
        local captured = document.capture(params.textDocument.uri)
        respond(id, callback, replied, function(reply)
          if not captured then
            return reply(nil, nil)
          end
          HANDLERS[method](document.open(captured), params, reply, snippets)
        end)
      elseif method == "shutdown" then
        respond(id, callback, replied, function(reply)
          reply(nil, nil)
        end)
      else
        respond(id, callback, replied, function(reply)
          reply({ code = ErrorCodes.MethodNotFound, message = method }, nil)
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
