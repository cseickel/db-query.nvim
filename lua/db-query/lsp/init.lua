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
local definition = require("db-query.lsp.definition")
local document = require("db-query.lsp.document")
local hover = require("db-query.lsp.hover")
local mainloop = require("db-query.mainloop")
local signature = require("db-query.lsp.signature")
local sqlContext = require("db-query.sql.context")

local M = {}

local NAME = "db-query"
local ErrorCodes = vim.lsp.protocol.ErrorCodes

--- Answers a request, at once or once a query has finished. `err` is an LSP
--- error, or anything else thrown, which answers as an internal error.
---@alias dbquery.LspReply fun(err: any, result: any)

--- A request about a sql buffer, with the cursor context read at its position.
---@class dbquery.LspRequest
---@field opened dbquery.Opened
---@field context dbquery.CursorContext
---@field offset integer The byte offset the context was read at.
---@field params table
---@field snippets boolean The client accepts snippets.

---@type table<string, fun(request: dbquery.LspRequest, reply: dbquery.LspReply)>
local HANDLERS = {
  ["textDocument/completion"] = function(request, reply)
    reply(nil, { isIncomplete = false, items = complete.items(request) })
  end,
  ["textDocument/signatureHelp"] = function(request, reply)
    reply(nil, signature.help(request.opened, request.context))
  end,
  ["textDocument/hover"] = function(request, reply)
    reply(nil, hover.hover(request.opened, request.context))
  end,
  ["textDocument/definition"] = function(request, reply)
    definition.locate(request.opened, request.context, reply)
  end,
  ["textDocument/references"] = function(request, reply)
    local declaration = vim.tbl_get(request.params, "context", "includeDeclaration") == true
    definition.references(request.opened, request.context, declaration, reply)
  end,
}

--- Hover, definition, and references send the position of the character under
--- the cursor, so `+ 1` reads the word that character is in.
local READS_CHARACTER = {
  ["textDocument/hover"] = true,
  ["textDocument/definition"] = true,
  ["textDocument/references"] = true,
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

  return {
    request = function(method, params, callback, replied)
      if closing then
        return false, nil
      end
      lastId = lastId + 1
      local id = lastId

      ---@type fun(reply: dbquery.LspReply)
      local answer
      if method == "initialize" then
        snippets = vim.tbl_get(params, "capabilities", "textDocument", "completion", "completionItem", "snippetSupport") == true
        answer = function(reply)
          reply(nil, {
            serverInfo = { name = NAME },
            capabilities = {
              positionEncoding = "utf-8",
              completionProvider = {
                triggerCharacters = { ".", "(", "'", '"' },
                completionItem = { labelDetailsSupport = true },
              },
              signatureHelpProvider = { triggerCharacters = { "(", "," } },
              hoverProvider = true,
              definitionProvider = true,
              referencesProvider = true,
            },
          })
        end
      elseif HANDLERS[method] then
        local captured = document.capture(params.textDocument.uri)
        answer = function(reply)
          if not captured then
            return reply(nil, nil)
          end
          local opened = document.open(captured)
          local offset = document.offset(opened.lines, params.position) + (READS_CHARACTER[method] and 1 or 0)
          HANDLERS[method]({
            opened = opened,
            context = sqlContext.at(opened.document, offset),
            offset = offset,
            params = params,
            snippets = snippets,
          }, reply)
        end
      elseif method == "shutdown" then
        answer = function(reply)
          reply(nil, nil)
        end
      else
        answer = function(reply)
          reply({ code = ErrorCodes.MethodNotFound, message = method }, nil)
        end
      end

      -- The first reply answers the request, now or once a query has
      -- finished. A cancelled request is only marked answered, as nvim's own
      -- rpc client does, so the requester never hears of it.
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
        mainloop.run(function()
          if pending[id] then
            return reply(nil, nil)
          end
          local ok, err = pcall(answer, reply)
          if not ok then
            reply(err, nil)
          end
        end)
      end)
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
