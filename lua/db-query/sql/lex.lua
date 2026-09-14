--[[
Splitting sql text into tokens, and tokens into statements.

- `tokens` reads postgres syntax: quoted identifiers, E'' strings, dollar
  quotes, nested block comments, `::`, `$1` parameters, psql `:var`
  interpolation, and psql backslash lines.
- `terminators` finds the tokens that end a statement, and `statements` splits
  at them, keeping a `begin atomic` body in the statement that declares it.
]]

local M = {}

---@alias dbquery.TokenKind
---| "word"
---| "quoted" A double-quoted identifier.
---| "string"
---| "dollar" A dollar-quoted string.
---| "comment"
---| "meta" A psql backslash command, which runs to the end of its line.
---| "param" A `$1` parameter.
---| "number"
---| "cast" The `::` operator.
---| "psql" A psql `:var`, `:'var'` or `:"var"` interpolation.
---| "operator"
---| "(" | ")" | "[" | "]" | "," | ";" | "."
---| "cursor" Placed where the cursor is, by `sql.context`.
---| "group" A parenthesized group, built by `syntax.groups`.
---| "other"

---@class dbquery.Token
---@field kind dbquery.TokenKind
---@field first integer Byte offset of the first character.
---@field last integer Byte offset of the last character.
---@field text string
---@field lower string
---@field open boolean The text ends inside this string, quoted identifier, dollar quote, comment, or psql command line. False for every other token.

local BACKSLASH, NEWLINE, SINGLE, DOUBLE = "\\", "\n", "'", '"'
local OPERATOR = "[%+%-%*/<>=~!@#%%%^&|`%?]"
local PUNCTUATION = "[%(%)%[%],;%.]"

--- Returns the `$tag$` of a dollar quote opened at `index`, or nil when no
--- dollar quote opens there.
---@param text string
---@param index integer
---@return string|nil
function M.dollarTag(text, index)
  return text:match("^%$[%a_]?[%w_]*%$", index)
end

--- Returns every token in `text`, comments included.
---@param text string
---@return dbquery.Token[]
function M.tokens(text)
  local tokens, index, size = {}, 1, #text

  local function add(kind, first, last, open)
    local raw = text:sub(first, last)
    tokens[#tokens + 1] = { kind = kind, first = first, last = last, text = raw, lower = raw:lower(), open = open == true }
  end

  --- Returns the index of the `quote` that closes the run of text starting at
  --- `from`, the character after the opening quote. A doubled quote, and a
  --- backslash pair when `escapes`, stay inside the run. Returns nil when the
  --- text ends first, or a newline does when `stopAtNewline`.
  local function closing(quote, from, escapes, stopAtNewline)
    local at = from
    while at <= size do
      local char = text:sub(at, at)
      if escapes and char == BACKSLASH then
        at = at + 2
      elseif char == quote then
        if text:sub(at + 1, at + 1) ~= quote then
          return at
        end
        at = at + 2
      elseif stopAtNewline and char == NEWLINE then
        return nil
      else
        at = at + 1
      end
    end
    return nil
  end

  while index <= size do
    local char, pair = text:sub(index, index), text:sub(index, index + 1)

    if char:match("%s") then
      index = index + 1
    elseif pair == "--" then
      local stop = text:find(NEWLINE, index, true)
      add("comment", index, stop or size, stop == nil)
      index = (stop or size) + 1
    elseif char == BACKSLASH then
      local stop = text:find(NEWLINE, index, true)
      add("meta", index, stop or size, stop == nil)
      index = (stop or size) + 1
    elseif pair == "/*" then
      local depth, at = 1, index + 2
      while at <= size and depth > 0 do
        local two = text:sub(at, at + 1)
        if two == "/*" then
          depth, at = depth + 1, at + 2
        elseif two == "*/" then
          depth, at = depth - 1, at + 2
        else
          at = at + 1
        end
      end
      add("comment", index, at - 1, depth > 0)
      index = at
    elseif char == SINGLE or (char:lower() == "e" and text:sub(index + 1, index + 1) == SINGLE) then
      local escapes = char ~= SINGLE
      local stop = closing(SINGLE, escapes and index + 2 or index + 1, escapes, false)
      add("string", index, stop or size, stop == nil)
      index = (stop or size) + 1
    elseif char == DOUBLE then
      local stop = closing(DOUBLE, index + 1, false, true)
      if stop then
        add("quoted", index, stop)
        index = stop + 1
      else
        -- An identifier still being typed ends at whitespace rather than
        -- swallowing the rest of the statement.
        local _, last = text:find("^[^%s]*", index + 1)
        add("quoted", index, last, true)
        index = last + 1
      end
    elseif text:match("^%$%d", index) then
      local _, last = text:find("^%$%d+", index)
      add("param", index, last)
      index = last + 1
    elseif M.dollarTag(text, index) then
      local tag = M.dollarTag(text, index)
      local close = text:find(tag, index + #tag, true)
      local last = close and close + #tag - 1 or size
      add("dollar", index, last, close == nil)
      index = last + 1
    elseif char:match("[%a_]") then
      local _, last = text:find("^[%w_$]*", index + 1)
      add("word", index, last)
      index = last + 1
    elseif char:match("%d") then
      local _, last = text:find("^[%d%.eE]*", index + 1)
      add("number", index, last)
      index = last + 1
    elseif pair == "::" then
      add("cast", index, index + 1)
      index = index + 2
    elseif char == ":" and text:match("^:['\"]?[%a_]", index) then
      local _, last = text:find("^:['\"]?[%w_]+['\"]?", index)
      add("psql", index, last)
      index = last + 1
    elseif char:match(PUNCTUATION) then
      add(char, index, index)
      index = index + 1
    elseif char:match(OPERATOR) then
      local _, last = text:find("^" .. OPERATOR .. "*", index + 1)
      -- Postgres ends an operator where a comment starts.
      local run = text:sub(index, last)
      local comment = math.min(run:find("--", 2, true) or math.huge, run:find("/*", 2, true) or math.huge)
      if comment ~= math.huge then
        last = index + comment - 2
      end
      add("operator", index, last)
      index = last + 1
    else
      add("other", index, index)
      index = index + 1
    end
  end
  return tokens
end

---@param token dbquery.Token|nil
---@param word string
---@return boolean
function M.isWord(token, word)
  return token ~= nil and token.kind == "word" and token.lower == word
end

--- Returns true for a word or a quoted identifier.
---@param token dbquery.Token|nil
---@return boolean
function M.isIdentifier(token)
  return token ~= nil and (token.kind == "word" or token.kind == "quoted")
end

--- Returns `tokens` without comments and psql backslash commands.
---@param tokens dbquery.Token[]
---@return dbquery.Token[]
function M.code(tokens)
  local kept = {}
  for _, token in ipairs(tokens) do
    if token.kind ~= "comment" and token.kind ~= "meta" then
      kept[#kept + 1] = token
    end
  end
  return kept
end

--- Returns how many `begin atomic` bodies are open after each token.
---
--- A `case` left open is forgotten at the next `;`, so a half-typed `case`
--- cannot take the `end` of a later body.
---@param tokens dbquery.Token[]
---@return integer[]
function M.atomicDepths(tokens)
  local depths, atomic, cases = {}, 0, 0
  for index, token in ipairs(tokens) do
    if M.isWord(token, "begin") and M.isWord(tokens[index + 1], "atomic") then
      atomic = atomic + 1
    elseif M.isWord(token, "case") then
      cases = cases + 1
    elseif M.isWord(token, "end") then
      if cases > 0 then
        cases = cases - 1
      elseif atomic > 0 then
        atomic = atomic - 1
      end
    elseif token.kind == ";" then
      cases = 0
    end
    depths[index] = atomic
  end
  return depths
end

--- psql commands that send the query typed before them, as `;` does.
local SENDS = { g = true, gx = true, gset = true, gexec = true, gdesc = true, watch = true, crosstabview = true }

---@param token dbquery.Token
---@return boolean
local function sendsQuery(token)
  if token.kind ~= "meta" then
    return false
  end
  return SENDS[token.lower:match("^\\(%a+)")] == true or token.text:match(";%s*$") ~= nil
end

--- Returns the tokens that end a statement, as a set: each `;` outside a
--- `begin atomic` body, each psql command line that ends in `;`, and each psql
--- command that sends the query, such as `\gset`.
---@param tokens dbquery.Token[]
---@return table<dbquery.Token, true>
function M.terminators(tokens)
  local found, depths = {}, M.atomicDepths(tokens)
  for index, token in ipairs(tokens) do
    if (token.kind == ";" and depths[index] == 0) or sendsQuery(token) then
      found[token] = true
    end
  end
  return found
end

--- Splits `tokens` at their terminators. A `;` belongs to no statement, and a
--- psql command line stays in the statement it ends. Every statement is
--- returned, including empty ones.
---@param tokens dbquery.Token[]
---@return dbquery.Token[][]
function M.statements(tokens)
  local ends = M.terminators(tokens)
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
