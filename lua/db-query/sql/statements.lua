--[[
Where one statement ends and the next begins.

- `terminators` finds the tokens that end a statement: a `;` outside the
  dialect's blocks, and a client command that sends the query.
- `split` divides tokens into statements at those terminators.
- `blockDepths` and `opensBlock` find the blocks, such as a `begin atomic`
  body, whose `;` stays inside the statement that declares them.
]]

local lex = require("db-query.sql.lex")

local M = {}

--- Returns how many words `tokens[index]` starts that open one of the
--- dialect's blocks, or nil when no block opens there.
---@param dialect dbquery.Dialect
---@param tokens dbquery.Token[]
---@param index integer
---@return integer|nil
function M.opensBlock(dialect, tokens, index)
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
function M.blockDepths(dialect, tokens)
  local depths, blocks, cases = {}, 0, 0
  for index, token in ipairs(tokens) do
    if M.opensBlock(dialect, tokens, index) then
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

--- Returns the tokens that end a statement, as a set: each `;` outside a
--- block, and each client command that sends the query, such as psql's
--- `\gset`.
---@param dialect dbquery.Dialect
---@param tokens dbquery.Token[]
---@return table<dbquery.Token, true>
function M.terminators(dialect, tokens)
  local found, depths = {}, M.blockDepths(dialect, tokens)
  local commands = dialect.commands
  for index, token in ipairs(tokens) do
    local sends = commands ~= nil and token.kind == "meta" and commands.sends(token.text)
    if (token.kind == ";" and depths[index] == 0) or sends then
      found[token] = true
    end
  end
  return found
end

--- Splits `tokens` at their terminators. A `;` belongs to no statement, and a
--- client command stays in the statement it ends. Every statement is returned,
--- including empty ones.
---@param dialect dbquery.Dialect
---@param tokens dbquery.Token[]
---@return dbquery.Token[][]
function M.split(dialect, tokens)
  local ends = M.terminators(dialect, tokens)
  local statements = { {} }
  for _, token in ipairs(tokens) do
    if token.kind ~= ";" or not ends[token] then
      table.insert(statements[#statements], token)
    end
    if ends[token] then
      statements[#statements + 1] = {}
    end
  end
  return statements
end

return M
