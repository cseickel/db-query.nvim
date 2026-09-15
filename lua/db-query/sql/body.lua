--[[
Code nested inside a statement.

- `at` finds the `do` block or function body holding the cursor, and the
  parameters and variables in scope there.
- `inLiteral` says whether the cursor is inside a string, a comment, a client
  command, or a dollar quote.
- `innerStatement` narrows a statement with a block, such as a `begin atomic`
  function, to the statement of its body holding the cursor.
]]

local lex = require("db-query.sql.lex")
local statements = require("db-query.sql.statements")

local M = {}

---@class dbquery.Body
---@field text string The code between the dollar quotes.
---@field offset integer Bytes of the enclosing text before the body.
---@field variables dbquery.Relation[] Parameters, declared variables, loop variables, and `new` and `old`.

local MODES = { ["in"] = true, out = true, inout = true, variadic = true }

--- Returns the index of the first token of the statement holding `tokens[index]`.
---@param dialect dbquery.Dialect
---@param tokens dbquery.Token[]
---@param index integer
---@return integer
local function statementStart(dialect, tokens, index)
  local terminators = statements.terminators(dialect, tokens)
  for at = index - 1, 1, -1 do
    if terminators[tokens[at]] then
      return at + 1
    end
  end
  return 1
end

--- Returns the named parameters of the function whose body is `tokens[index]`.
---@param tokens dbquery.Token[]
---@param start integer First token of the statement.
---@param index integer
---@return dbquery.Relation[]
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
  local function read()
    local first = entry[1] and MODES[entry[1].lower] and 2 or 1
    local name, type = entry[first], entry[first + 1]
    if lex.isIdentifier(name) and lex.isIdentifier(type) and not lex.isWord(type, "default") then
      variables[#variables + 1] = { kind = "variable", alias = name.text }
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
      read()
    elseif token.kind ~= "comment" then
      entry[#entry + 1] = token
    end
  end
  if #entry > 0 then
    read()
  end
  return variables
end

--- Returns the variables a plpgsql body declares, and the variables of its
--- `for <name> in` loops.
---@param tokens dbquery.Token[] Code tokens of the body.
---@return dbquery.Relation[]
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
      local before = index - 1
      while before >= 1 and tokens[before].kind == "comment" do
        before = before - 1
      end
      if not (lex.isWord(tokens[before], "do") or lex.isWord(tokens[before], "as")) then
        return nil
      end

      local inner = text:sub(first, last)
      local start = statementStart(dialect, tokens, index)
      local variables = parameters(tokens, start, index)
      vim.list_extend(variables, declarations(lex.code(lex.tokens(dialect, inner))))
      for at = start, index - 1 do
        if lex.isWord(tokens[at], "returns") and lex.isWord(tokens[at + 1], "trigger") then
          variables[#variables + 1] = { kind = "trigger_row", alias = "new" }
          variables[#variables + 1] = { kind = "trigger_row", alias = "old" }
          break
        end
      end
      return { text = inner, offset = first - 1, variables = variables }
    end
  end
  return nil
end

--- Returns true when `cursor` is inside a string, comment, client command, or
--- dollar quote.
---@param tokens dbquery.Token[]
---@param cursor integer
---@return boolean
function M.inLiteral(tokens, cursor)
  for _, token in ipairs(tokens) do
    local literal = token.kind == "string" or token.kind == "comment" or token.kind == "dollar" or token.kind == "meta"
    if literal and token.first < cursor and (cursor <= token.last or token.open) then
      return true
    end
  end
  return false
end

--- Returns the statement of a block's body holding `marker`, or `statement`
--- itself when the marker is outside every block.
---@param dialect dbquery.Dialect
---@param statement dbquery.Token[]
---@param marker dbquery.Token
---@return dbquery.Token[]
function M.innerStatement(dialect, statement, marker)
  local markerIndex = 1
  for index, token in ipairs(statement) do
    if token == marker then
      markerIndex = index
    end
  end
  if markerIndex == 1 or statements.blockDepths(dialect, statement)[markerIndex - 1] == 0 then
    return statement
  end

  local first, last = 1, #statement
  for index = markerIndex - 1, 1, -1 do
    local opener = statements.opensBlock(dialect, statement, index)
    if statement[index].kind == ";" or opener then
      first = index + (opener or 1)
      break
    end
  end
  for index = markerIndex + 1, #statement do
    if statement[index].kind == ";" then
      last = index - 1
      break
    end
  end
  if lex.isWord(statement[last], "end") then
    last = last - 1
  end
  return vim.list_slice(statement, first, last)
end

return M
