--[[
Splitting sql text into tokens.

`tokens` reads the text by the rules of a `dbquery.Dialect`: its strings,
quoted identifiers, comments, parameters, and client commands. Every dialect
produces the same token kinds, so nothing after the lexer depends on how the
text was quoted.
]]

local M = {}

---@alias dbquery.TokenKind
---| "word"
---| "quoted" A quoted identifier.
---| "string"
---| "dollar" A dollar-quoted string.
---| "comment"
---| "meta" A client command, such as psql's `\gset` or mysql's `delimiter //`.
---| "param" A parameter or variable, such as `$1` or `@total`.
---| "number"
---| "cast" The `::` operator.
---| "variable" A client variable, such as psql's `:name`.
---| "operator"
---| "(" | ")" | "[" | "]" | "," | "."
---| ";" Ends a statement: a `;`, or the delimiter a client command set in its place.
---| "separator" A `;` while a client command has set another delimiter, so the client sends it with the statement.
---| "cursor" Marks where the cursor is, and holds no text.
---| "group" A nested parenthesized group, whose items are in `token.group`.
---| "other"

---@class dbquery.Token
---@field kind dbquery.TokenKind
---@field first integer Byte offset of the first character.
---@field last integer Byte offset of the last character.
---@field text string
---@field lower string
---@field open boolean The text ends inside this string, quoted identifier, dollar quote, comment, or client command. False for every other token.
---@field reserved boolean A word the dialect never reads as an alias. False for every other token.

local BACKSLASH, NEWLINE, SINGLE = "\\", "\n", "'"
local OPERATOR = "[%+%-%*/<>=~!@#%%%^&|`%?]"
local PUNCTUATION = "[%(%)%[%],;%.]"

--- Token kinds that end where a client-set delimiter starts, as in mysql's `end//`.
local UNQUOTED = { word = true, number = true, param = true, operator = true }

--- Returns the `$tag$` of a dollar quote opened at `index`, or nil when no
--- dollar quote opens there.
---@param text string
---@param index integer
---@return string|nil
function M.dollarTag(text, index)
  return text:match("^%$[%a_]?[%w_]*%$", index)
end

---@param patterns string[]
---@param text string
---@param index integer
---@return string|nil
local function matching(patterns, text, index)
  for _, pattern in ipairs(patterns) do
    local found = text:match(pattern, index)
    if found then
      return found
    end
  end
  return nil
end

--- Returns every token in `text`, comments included.
---@param dialect dbquery.Dialect
---@param text string
---@return dbquery.Token[]
function M.tokens(dialect, text)
  local rules, commands = dialect.lex, dialect.commands
  local tokens, index, size = {}, 1, #text
  local delimiter, lineStart = ";", true

  local function add(kind, first, last, open)
    local raw = text:sub(first, last)
    local lower = raw:lower()
    tokens[#tokens + 1] = {
      kind = kind,
      first = first,
      last = last,
      text = raw,
      lower = lower,
      open = open == true,
      reserved = kind == "word" and dialect.reserved[lower] == true,
    }
    lineStart = raw:sub(-1) == NEWLINE
  end

  ---@param at integer
  ---@return boolean
  local function lineComment(at)
    for _, pattern in ipairs(rules.lineComments) do
      if text:find(pattern, at) then
        return true
      end
    end
    return false
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

  --- Returns the kind, last byte, and open flag of the token starting at
  --- `index`, which is not whitespace.
  ---@param char string The character at `index`.
  ---@return dbquery.TokenKind kind
  ---@return integer last
  ---@return boolean open
  local function scan(char)
    local pair = text:sub(index, index + 1)

    if delimiter ~= ";" and text:sub(index, index + #delimiter - 1) == delimiter then
      return ";", index + #delimiter - 1, false
    end
    if lineComment(index) then
      local last = text:find(NEWLINE, index, true) or size
      return "comment", last, text:sub(last, last) ~= NEWLINE
    end
    local command = commands and commands.at(text, index, lineStart)
    if command then
      delimiter = commands.delimiter and commands.delimiter(text:sub(index, command)) or delimiter
      return "meta", command, command == size and text:sub(command, command) ~= NEWLINE
    end
    if pair == "/*" then
      local depth, at = 1, index + 2
      while at <= size and depth > 0 do
        local two = text:sub(at, at + 1)
        if two == "/*" and rules.nestedComments then
          depth, at = depth + 1, at + 2
        elseif two == "*/" then
          depth, at = depth - 1, at + 2
        else
          at = at + 1
        end
      end
      return "comment", at - 1, depth > 0
    end
    local escaped = rules.escapeStrings and char:lower() == "e" and text:sub(index + 1, index + 1) == SINGLE
    if rules.strings[char] ~= nil or escaped then
      local stop = closing(escaped and SINGLE or char, escaped and index + 2 or index + 1, escaped or rules.strings[char], false)
      return "string", stop or size, stop == nil
    end
    if rules.identifiers[char] then
      local stop = closing(rules.identifiers[char], index + 1, false, true)
      -- An identifier still being typed ends at whitespace rather than
      -- swallowing the rest of the statement.
      return "quoted", stop or select(2, text:find("^[^%s]*", index + 1)), stop == nil
    end
    local parameter = matching(rules.parameters, text, index)
    if parameter then
      return "param", index + #parameter - 1, false
    end
    local tag = rules.dollarQuotes and M.dollarTag(text, index)
    if tag then
      local close = text:find(tag, index + #tag, true)
      return "dollar", close and close + #tag - 1 or size, close == nil
    end
    if char:match("[%a_]") then
      return "word", select(2, text:find("^[%w_$]*", index + 1)), false
    end
    if char:match("%d") then
      return "number", select(2, text:find("^[%d%.eE]*", index + 1)), false
    end
    if rules.casts and pair == "::" then
      return "cast", index + 1, false
    end
    local variable = commands and commands.variables and text:match(commands.variables, index)
    if variable then
      return "variable", index + #variable - 1, false
    end
    if char:match(PUNCTUATION) then
      return (char == ";" and delimiter ~= ";") and "separator" or char, index, false
    end
    if char:match(OPERATOR) then
      local last = select(2, text:find("^" .. OPERATOR .. "*", index + 1))
      for at = index + 1, last do
        if lineComment(at) or text:sub(at, at + 1) == "/*" then
          return "operator", at - 1, false
        end
      end
      return "operator", last, false
    end
    return "other", index, false
  end

  while index <= size do
    local char = text:sub(index, index)
    if char:match("%s") then
      lineStart = lineStart or char == NEWLINE
      index = index + 1
    else
      local kind, last, open = scan(char)
      if UNQUOTED[kind] and delimiter ~= ";" then
        local found = text:sub(index, last):find(delimiter, 2, true)
        last = found and index + found - 2 or last
      end
      add(kind, index, last, open)
      index = last + 1
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

--- Returns `tokens` without comments and client commands.
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

return M
