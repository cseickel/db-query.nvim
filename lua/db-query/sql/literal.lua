--[[
Reads the string the cursor is in, and finds the column or type its value is
compared to or cast to.
]]

local lex = require("db-query.sql.lex")
local syntax = require("db-query.sql.syntax")

local M = {}

--- Words that may stand between a column and a value compared with it.
local COMPARISONS = {
  ["in"] = true, like = true, ilike = true, ["not"] = true, is = true, similar = true, to = true,
  glob = true, match = true, regexp = true, rlike = true, any = true, all = true, some = true,
  between = true,
}

--- Returns the text of string `token` between its quotes, on the line the
--- cursor is on.
---@param token dbquery.Token
---@param cursor integer
---@return dbquery.Word
function M.word(token, cursor)
  local closed = not token.open
  local first = token.first + 1
  local text = token.text:sub(2, closed and -2 or -1)
  local opens = text:sub(1, cursor - first):find("\n[^\n]*$")
  if opens then
    first, text = first + opens, text:sub(opens + 1)
  end
  local ends = text:find("\n", 1, true)
  if ends then
    text = text:sub(1, ends - 1)
  end
  return { text = text, first = first, last = first + #text - 1 }
end

--- Returns the name of the column a value at `index` is compared to or written
--- into, reading back over the comparison that precedes it.
---@param items dbquery.Token[]
---@param index integer
---@return string|nil
function M.comparedName(items, index)
  local at, compared = index - 1, false
  while items[at] ~= nil and (items[at].kind == "operator" or (items[at].kind == "word" and COMPARISONS[items[at].lower])) do
    compared, at = true, at - 1
  end
  return compared and (syntax.nameBefore(items, at)) or nil
end

--- Returns the name of the type a value at `index` is cast to, written either
--- as `'x'::mood` or as `cast('x' as mood)`.
---@param items dbquery.Token[]
---@param index integer
---@param call dbquery.Call|nil The call holding the cursor.
---@return string|nil
function M.castName(items, index, call)
  local after = items[index + 1]
  if after == nil then
    return nil
  end
  if after.kind == "cast" then
    return (syntax.nameAt(items, index + 2))
  end
  local casting = call ~= nil and call.name:lower() == "cast" and call.argument == 1
  return casting and lex.isWord(after, "as") and (syntax.nameAt(items, index + 2)) or nil
end

return M
