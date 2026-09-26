--[[
SQL parsing for output routing and for the statement the cursor is in.

Determines whether a statement returns rows, and if so whether it can be
wrapped in COPY. A statement that returns no rows writes nothing but its
transcript, which belongs in the log.

Every function here reads tokens from `sql.lex` by the rules of the dialect it
is given, so a semicolon or keyword inside a string, a comment, or a
dollar-quoted body is never mistaken for code.
]]

local lex = require("db-query.sql.lex")
local statements = require("db-query.sql.statements")

local M = {}

---@alias dbquery.RowKind "query"|"returning"

--- Removes the trailing semicolons, which are a syntax error inside
--- `COPY (...)`, and every semicolon ending an empty statement, so
--- `select 1;;` becomes `select 1` and `a;; b;` becomes `a; b`. Comments stay.
---@param dialect dbquery.Dialect
---@param sql string
---@return string
function M.stripTerminator(dialect, sql)
  local code = lex.code(lex.tokens(dialect, sql))
  local ends = statements.terminators(dialect, code)
  local lastCode = 0
  for index, token in ipairs(code) do
    if token.kind ~= ";" then
      lastCode = index
    end
  end
  local pieces, from, empty = {}, 1, true
  for index, token in ipairs(code) do
    if token.kind == ";" and (index > lastCode or (ends[token] and empty)) then
      table.insert(pieces, sql:sub(from, token.first - 1))
      from = token.last + 1
    end
    empty = ends[token] == true
  end
  table.insert(pieces, sql:sub(from))
  return table.concat(pieces)
end

--- Returns the last `delimiter` command in `lines`, such as mysql's
--- `delimiter //`, or nil when the lines set none or set it back to `;`.
---@param dialect dbquery.Dialect
---@param lines string[]
---@return string|nil
function M.delimiterCommand(dialect, lines)
  local delimiterOf = dialect.commands and dialect.commands.delimiter
  if not delimiterOf then
    return nil
  end
  local command = nil
  for _, token in ipairs(lex.tokens(dialect, table.concat(lines, "\n"))) do
    local newDelimiter = token.kind == "meta" and delimiterOf(token.text)
    if newDelimiter then
      command = newDelimiter ~= ";" and vim.trim(token.text) or nil
    end
  end
  return command
end

---@param line string|nil
---@return boolean
local function blank(line)
  return line == nil or line:match("^%s*$") ~= nil
end

--- Returns the line span of the statement containing `row`, or nil for blank
--- lines. A line holding a terminator, as `statements.terminators` defines
--- one, is the last line of its statement, so statements sharing a line are
--- returned together.
---@param dialect dbquery.Dialect
---@param lines string[]
---@param row integer 0-based line number.
---@return [integer, integer]|nil
function M.statementAt(dialect, lines, row)
  local lineStarts, offset = {}, 1
  for index, line in ipairs(lines) do
    lineStarts[index] = offset
    offset = offset + #line + 1
  end

  local tokens = {}
  for _, token in ipairs(lex.tokens(dialect, table.concat(lines, "\n"))) do
    if token.kind ~= "comment" then
      tokens[#tokens + 1] = token
    end
  end
  local terminators = statements.terminators(dialect, tokens)
  local endRows, line = {}, 1
  for _, token in ipairs(tokens) do
    if terminators[token] then
      while lineStarts[line + 1] and lineStarts[line + 1] <= token.first do
        line = line + 1
      end
      endRows[line - 1] = true
    end
  end

  local first, last = 0, #lines - 1
  for earlierRow = row - 1, 0, -1 do
    if endRows[earlierRow] then
      first = earlierRow + 1
      break
    end
  end
  for laterRow = row, #lines - 1 do
    if endRows[laterRow] then
      last = laterRow
      break
    end
  end

  while first < last and blank(lines[first + 1]) do
    first = first + 1
  end
  while last > first and blank(lines[last + 1]) do
    last = last - 1
  end

  if blank(lines[first + 1]) then
    return nil
  end
  return { first, last }
end

--- Returns `span` with its first line moved down to the line where the first
--- token of `lines` that is not a comment starts, or `span` as it is when every
--- token is a comment.
---@param dialect dbquery.Dialect
---@param lines string[] The lines `span` covers.
---@param span [integer, integer] First and last line (0-based).
---@return [integer, integer]
function M.codeSpan(dialect, lines, span)
  local text = table.concat(lines, "\n")
  for _, token in ipairs(lex.tokens(dialect, text)) do
    if token.kind ~= "comment" then
      local skipped = select(2, text:sub(1, token.first - 1):gsub("\n", ""))
      return { span[1] + skipped, span[2] }
    end
  end
  return span
end

--- Returns true when any statement in `sql` starts with one of the dialect's
--- `definitions`, such as `create` or `drop`, and so may change the catalog.
---@param dialect dbquery.Dialect
---@param sql string
---@return boolean
function M.defines(dialect, sql)
  for _, statement in ipairs(statements.split(dialect, lex.code(lex.tokens(dialect, sql)))) do
    for _, token in ipairs(statement) do
      if token.kind ~= "meta" then
        if token.kind == "word" and dialect.definitions[token.lower] then
          return true
        end
        break
      end
    end
  end
  return false
end

local ROW_SOURCES = { select = true, ["with"] = true, table = true, values = true }

local WRITES = { insert = true, update = true, delete = true, merge = true }

--- Returns "query" for a statement COPY accepts (select, with, table, values),
--- "returning" for an insert, update, delete, or merge with RETURNING, and nil
--- otherwise. Text holding more than one statement or a client command returns
--- nil. A mysql `delimiter` line is ignored.
---@param dialect dbquery.Dialect
---@param sql string
---@return dbquery.RowKind|nil
function M.rowKind(dialect, sql)
  local delimiterOf = dialect.commands and dialect.commands.delimiter
  for _, token in ipairs(lex.tokens(dialect, sql)) do
    if token.kind == "meta" and not (delimiterOf and delimiterOf(token.text)) then
      return nil
    end
  end
  local code = lex.code(lex.tokens(dialect, M.stripTerminator(dialect, sql)))
  if #statements.split(dialect, code) > 1 then
    return nil
  end

  local firstWord = code[1] and code[1].kind == "word" and code[1].lower or ""
  local hasWrite, returning = false, false
  for _, token in ipairs(code) do
    hasWrite = hasWrite or (token.kind == "word" and WRITES[token.lower] == true)
    returning = returning or lex.isWord(token, "returning")
  end

  if ROW_SOURCES[firstWord] then
    -- Postgres refuses a data-modifying CTE inside COPY.
    if firstWord == "with" and hasWrite then
      return nil
    end
    return "query"
  end
  if WRITES[firstWord] and returning then
    return "returning"
  end
  return nil
end

return M
