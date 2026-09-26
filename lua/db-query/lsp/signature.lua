--[[
Signature help for the function call holding the cursor.

The dialect's grammar forms, such as `extract(field from source)`, come first,
then every overload the catalog holds under that name. Postgres has both for
some names: `position(a in b)` is grammar for the catalog's `position(b, a)`.
]]

local describe = require("db-query.lsp.describe")
local names = require("db-query.lsp.names")

local M = {}

--- Returns the parameter an argument number points at, counting from 0. An
--- argument past the last parameter that does not repeat points at `count`,
--- which the protocol reads as no parameter.
---@param argument integer Counting from 1.
---@param count integer
---@param variadic boolean
---@return integer
local function activeParameter(argument, count, variadic)
  if argument > count then
    return (variadic and count > 0) and count - 1 or count
  end
  return argument - 1
end

---@param name string
---@param fn dbquery.Function
---@param argument integer
---@return lsp.SignatureInformation
local function overload(name, fn, argument)
  local args = describe.passed(fn)
  local argLabels = vim.tbl_map(describe.argument, args)
  local label = name .. "(" .. table.concat(argLabels, ", ") .. ")" .. (fn.result and (" → " .. fn.result) or "")
  local parameters, offset = {}, #name + 1
  for index, argLabel in ipairs(argLabels) do
    parameters[index] = { label = { offset, offset + #argLabel } }
    offset = offset + #argLabel + 2
  end
  local lastArg = args[#args]
  return {
    label = label,
    documentation = fn.comment,
    parameters = parameters,
    activeParameter = activeParameter(argument, #args, lastArg ~= nil and lastArg.mode == "variadic"),
  }
end

--- Returns the signature of a grammar form. A parameter whose name the label
--- does not hold is labeled by its name alone.
---@param grammar dbquery.GrammarSignature
---@param argument integer
---@return lsp.SignatureInformation
local function form(grammar, argument)
  local parameters = {}
  local searchFrom = grammar.label:find("(", 1, true)
  for index, name in ipairs(grammar.parameters) do
    local start = grammar.label:find(name, searchFrom, true)
    if start then
      parameters[index] = { label = { start - 1, start - 1 + #name } }
      searchFrom = start + #name
    else
      parameters[index] = { label = name }
    end
  end
  return {
    label = grammar.label,
    parameters = parameters,
    activeParameter = #parameters > 0 and activeParameter(argument, #parameters, grammar.variadic) or nil,
  }
end

--- Returns the signature help for the call in `context`, or nil when the
--- cursor is in no call anything is known about.
---@param opened dbquery.Opened
---@param context dbquery.CursorContext
---@return lsp.SignatureHelp|nil
function M.help(opened, context)
  local call = context.call
  if not call or not call.name then
    return nil
  end
  local dialect = opened.document.dialect
  local parts = names.parts(dialect, call.name)
  local signatures = {}
  local grammar = #parts == 1 and dialect.signatures[parts[1].text:lower()]
  if grammar then
    signatures[#signatures + 1] = form(grammar, call.argument)
  end
  if opened.catalog then
    for _, fn in ipairs(names.functions(opened.catalog, dialect, call.name)) do
      signatures[#signatures + 1] = overload(parts[#parts].text, fn, call.argument)
    end
  end
  if #signatures == 0 then
    return nil
  end
  return { signatures = signatures, activeSignature = 0 }
end

return M
