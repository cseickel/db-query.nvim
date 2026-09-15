--[[
Signature help for the function call holding the cursor.

The dialect's grammar forms, such as `extract(field from source)`, come first,
then every overload the catalog holds under that name. Postgres has both for
some names: `position(a in b)` is grammar for the catalog's `position(b, a)`.
]]

local names = require("db-query.lsp.names")

local M = {}

--- Returns the arguments a call of `fn` passes: never a table argument, and an
--- out argument only to a procedure.
---@param fn dbquery.Function
---@return dbquery.Argument[]
local function passed(fn)
  return vim.iter(fn.args):filter(function(arg)
    return arg.mode ~= "table" and (arg.mode ~= "out" or fn.kind == "procedure")
  end):totable()
end

---@param arg dbquery.Argument
---@return string
local function describe(arg)
  local parts = {}
  if arg.mode ~= "in" then
    parts[#parts + 1] = arg.mode
  end
  parts[#parts + 1] = arg.name
  parts[#parts + 1] = arg.type
  local text = table.concat(parts, " ")
  if text == "" then
    text = "value"
  end
  return arg.default and ("[" .. text .. "]") or text
end

--- Returns the parameter an argument number points at, counting from 0. An
--- argument past the last parameter that does not repeat points at `count`,
--- which the protocol reads as no parameter.
---@param argument integer Counting from 1.
---@param count integer
---@param variadic boolean
---@return integer
local function active(argument, count, variadic)
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
  local args = passed(fn)
  local labels = vim.tbl_map(describe, args)
  local label = name .. "(" .. table.concat(labels, ", ") .. ")" .. (fn.result and (" → " .. fn.result) or "")
  local parameters, at = {}, #name + 1
  for index, text in ipairs(labels) do
    parameters[index] = { label = { at, at + #text } }
    at = at + #text + 2
  end
  local last = args[#args]
  return {
    label = label,
    documentation = fn.comment,
    parameters = parameters,
    activeParameter = active(argument, #args, last ~= nil and last.mode == "variadic"),
  }
end

---@param grammar dbquery.GrammarSignature
---@param argument integer
---@return lsp.SignatureInformation
local function form(grammar, argument)
  local parameters = {}
  local from = grammar.label:find("(", 1, true)
  for index, name in ipairs(grammar.parameters) do
    local first = grammar.label:find(name, from, true)
    parameters[index] = { label = { first - 1, first - 1 + #name } }
    from = first + #name
  end
  return {
    label = grammar.label,
    parameters = parameters,
    activeParameter = #parameters > 0 and active(argument, #parameters, grammar.variadic) or nil,
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
