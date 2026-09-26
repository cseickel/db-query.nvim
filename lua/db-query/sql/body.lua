--[[
The body of a `do` block or function, and the variables in scope inside it.
]]

local lex = require("db-query.sql.lex")
local statements = require("db-query.sql.statements")

local M = {}

---@class dbquery.Body
---@field text string The code between the dollar quotes.
---@field offset integer Bytes of the enclosing text before the body.
---@field variables dbquery.ScopeRelation[] Parameters, declared variables, loop variables, and `new` and `old`.

local PARAMETER_MODES = { ["in"] = true, out = true, inout = true, variadic = true }

--- Returns the named parameters of the function whose body is `tokens[index]`.
---@param tokens dbquery.Token[]
---@param start integer First token of the statement.
---@param index integer
---@return dbquery.ScopeRelation[]
local function parameters(tokens, start, index)
  local at = start
  while at < index and not (lex.isWord(tokens[at], "function") or lex.isWord(tokens[at], "procedure")) do
    at = at + 1
  end
  local open = at + 1
  while open < index and tokens[open].kind ~= "(" do
    open = open + 1
  end
  if open >= index then
    return {}
  end

  local variables, entry, depth = {}, {}, 0
  local function addParameter()
    local first = entry[1] and PARAMETER_MODES[entry[1].lower] and 2 or 1
    local nameToken, typeToken = entry[first], entry[first + 1]
    if lex.isIdentifier(nameToken) and lex.isIdentifier(typeToken) and not lex.isWord(typeToken, "default") then
      variables[#variables + 1] = { kind = "variable", alias = nameToken.text }
    end
    entry = {}
  end
  for position = open + 1, index - 1 do
    local token = tokens[position]
    if token.kind == "(" or token.kind == "[" then
      depth = depth + 1
    elseif token.kind == ")" or token.kind == "]" then
      if depth == 0 then
        break
      end
      depth = depth - 1
    end
    if token.kind == "," and depth == 0 then
      addParameter()
    elseif token.kind ~= "comment" then
      entry[#entry + 1] = token
    end
  end
  if #entry > 0 then
    addParameter()
  end
  return variables
end

--- Returns the variables a plpgsql body declares, and the variables of its
--- `for <name> in` loops.
---@param tokens dbquery.Token[] Code tokens of the body.
---@return dbquery.ScopeRelation[]
local function declarations(tokens)
  local variables, declaring, fresh = {}, false, false
  for index, token in ipairs(tokens) do
    if lex.isWord(token, "for") and lex.isIdentifier(tokens[index + 1]) and lex.isWord(tokens[index + 2], "in") then
      variables[#variables + 1] = { kind = "variable", alias = tokens[index + 1].text }
    end
    if lex.isWord(token, "declare") then
      declaring, fresh = true, true
    elseif lex.isWord(token, "begin") then
      declaring = false
    elseif declaring and token.kind == ";" then
      fresh = true
    elseif declaring and fresh and lex.isIdentifier(token) then
      variables[#variables + 1] = { kind = "variable", alias = token.text }
      fresh = false
    else
      fresh = false
    end
  end
  return variables
end

--- Returns the body of the `do` block or function holding `cursor`, or nil
--- when the cursor is not in one. A body is a dollar quote preceded, comments
--- aside, by `do` or `as`.
---@param document dbquery.Document
---@param cursor integer
---@return dbquery.Body|nil
function M.at(document, cursor)
  local text, tokens, dialect = document.text, document.tokens, document.dialect
  for index, token in ipairs(tokens) do
    local tag = token.kind == "dollar" and lex.dollarTag(text, token.first)
    if tag and token.first < cursor and cursor <= token.last + 1 then
      local first = token.first + #tag
      local last = token.open and token.last or token.last - #tag
      if cursor < first or cursor > last + 1 then
        return nil
      end
      local previousIndex = index - 1
      while previousIndex >= 1 and tokens[previousIndex].kind == "comment" do
        previousIndex = previousIndex - 1
      end
      if not (lex.isWord(tokens[previousIndex], "do") or lex.isWord(tokens[previousIndex], "as")) then
        return nil
      end

      local bodyText = text:sub(first, last)
      local terminators = statements.terminators(dialect, tokens)
      local start = 1
      for at = index - 1, 1, -1 do
        if terminators[tokens[at]] then
          start = at + 1
          break
        end
      end
      local variables = parameters(tokens, start, index)
      vim.list_extend(variables, declarations(lex.code(lex.tokens(dialect, bodyText))))
      for at = start, index - 1 do
        if lex.isWord(tokens[at], "returns") and lex.isWord(tokens[at + 1], "trigger") then
          variables[#variables + 1] = { kind = "trigger_row", alias = "new" }
          variables[#variables + 1] = { kind = "trigger_row", alias = "old" }
          break
        end
      end
      return { text = bodyText, offset = first - 1, variables = variables }
    end
  end
  return nil
end

return M
