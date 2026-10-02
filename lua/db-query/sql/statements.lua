--[[
Finds where one statement ends and the next begins.
]]

local lex = require("db-query.sql.lex")
local literals = require("db-query.sql.literal")
local syntax = require("db-query.sql.syntax")

local M = {}

---@class dbquery.Word
---@field text string The whole identifier under the cursor, or "" when the cursor is between tokens.
---@field first integer Byte offset of its first character.
---@field last integer Byte offset of its last character, `first - 1` when empty.

--- Returns how many words `tokens[index]` starts that open one of the
--- dialect's blocks, such as a `begin atomic` body, or nil when no block opens
--- there.
---@param dialect dbquery.Dialect
---@param tokens dbquery.Token[]
---@param index integer
---@return integer|nil
local function opensBlock(dialect, tokens, index)
  for _, words in ipairs(dialect.blocks) do
    local matched = true
    for offset, word in ipairs(words) do
      matched = matched and lex.isWord(tokens[index + offset - 1], word)
    end
    if matched then
      return #words
    end
  end
  return nil
end

--- Returns how many of the dialect's blocks are open after each token.
---
--- A `case` left open is forgotten at the next `;`, so a half-typed `case`
--- cannot take the `end` of a later block.
---@param dialect dbquery.Dialect
---@param tokens dbquery.Token[]
---@return integer[]
local function blockDepths(dialect, tokens)
  local depths, blocks, cases = {}, 0, 0
  for index, token in ipairs(tokens) do
    if opensBlock(dialect, tokens, index) then
      blocks = blocks + 1
    elseif lex.isWord(token, "case") then
      cases = cases + 1
    elseif lex.isWord(token, "end") then
      if cases > 0 then
        cases = cases - 1
      elseif blocks > 0 then
        blocks = blocks - 1
      end
    elseif token.kind == ";" then
      cases = 0
    end
    depths[index] = blocks
  end
  return depths
end

--- Returns the set of tokens that end a statement. Those are each `;` outside
--- a block, and each client command that sends the query, such as psql's
--- `\gset`.
---@param dialect dbquery.Dialect
---@param tokens dbquery.Token[]
---@return table<dbquery.Token, true>
function M.terminators(dialect, tokens)
  local terminators, depths = {}, blockDepths(dialect, tokens)
  local commands = dialect.commands
  for index, token in ipairs(tokens) do
    local sends = commands ~= nil and token.kind == "meta" and commands.sends(token.text)
    if (token.kind == ";" and depths[index] == 0) or sends then
      terminators[token] = true
    end
  end
  return terminators
end

--- Splits `tokens` at their terminators. A `;` belongs to no statement, and a
--- client command stays in the statement it ends. Every statement is returned,
--- including empty ones.
---@param dialect dbquery.Dialect
---@param tokens dbquery.Token[]
---@return dbquery.Token[][]
function M.split(dialect, tokens)
  local terminators = M.terminators(dialect, tokens)
  local statements = { {} }
  for _, token in ipairs(tokens) do
    if token.kind ~= ";" or not terminators[token] then
      table.insert(statements[#statements], token)
    end
    if terminators[token] then
      statements[#statements + 1] = {}
    end
  end
  return statements
end

--- Returns the statement of a block's body holding `marker`, or `statement`
--- itself when the marker is outside every block.
---@param dialect dbquery.Dialect
---@param statement dbquery.Token[]
---@param marker dbquery.Token
---@return dbquery.Token[]
local function innerStatement(dialect, statement, marker)
  local markerIndex = 1
  for index, token in ipairs(statement) do
    if token == marker then
      markerIndex = index
    end
  end
  if markerIndex == 1 or blockDepths(dialect, statement)[markerIndex - 1] == 0 then
    return statement
  end

  local first, last = 1, #statement
  for index = markerIndex - 1, 1, -1 do
    local opener = opensBlock(dialect, statement, index)
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

--- Returns the code tokens of the statement holding `cursor`, with a cursor
--- token in place of the identifier under it, and that identifier. Inside a
--- block such as a `begin atomic` body, the statement is the body's own
--- statement.
---@param dialect dbquery.Dialect
---@param tokens dbquery.Token[] Every token of the text.
---@param cursor integer
---@param literal dbquery.Token|nil The string holding the cursor, which the marker stands in for whole.
---@return dbquery.Token[] statement
---@return dbquery.Word word
function M.atCursor(dialect, tokens, cursor, literal)
  local marker = syntax.marker("cursor", cursor)
  local word = { text = "", first = cursor, last = cursor - 1 }
  local markerPlaced, withMarker = false, {}
  -- Client commands stay until the statements are split, because some of
  -- them end a statement.
  for _, token in ipairs(tokens) do
    local underCursor = token == literal
      or (literal == nil and lex.isIdentifier(token) and token.first < cursor and cursor <= token.last + 1)
    if not markerPlaced and (underCursor or token.first >= cursor) then
      withMarker[#withMarker + 1] = marker
      markerPlaced = true
      if underCursor then
        word = literal and literals.word(token, cursor) or { text = token.text, first = token.first, last = token.last }
      end
    end
    if token.kind ~= "comment" and not underCursor then
      withMarker[#withMarker + 1] = token
    end
  end
  if not markerPlaced then
    withMarker[#withMarker + 1] = marker
  end

  for _, statement in ipairs(M.split(dialect, withMarker)) do
    if vim.list_contains(statement, marker) then
      return innerStatement(dialect, lex.code(statement), marker), word
    end
  end
  error("the cursor token belongs to no statement")
end

return M
