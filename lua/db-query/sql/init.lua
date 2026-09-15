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

--- Removes the statement's trailing semicolon, which is a syntax error inside
--- `COPY (...)`. A comment after the semicolon stays.
---@param dialect dbquery.Dialect
---@param sql string
---@return string
function M.stripTerminator(dialect, sql)
  local code = lex.code(lex.tokens(dialect, sql))
  local last = code[#code]
  if not (last and last.kind == ";") then
    return sql
  end
  return sql:sub(1, last.first - 1) .. sql:sub(last.last + 1)
end

--- Returns the last `delimiter` line in `lines`, such as mysql's
--- `delimiter //`. Returns nil when the lines set no delimiter, or set it back
--- to `;`. Sql taken from below those lines needs this line sent ahead of it,
--- so the client ends its statements where the buffer does.
---@param dialect dbquery.Dialect
---@param lines string[]
---@return string|nil
function M.delimiterCommand(dialect, lines)
  local delimiter = dialect.commands and dialect.commands.delimiter
  if not delimiter then
    return nil
  end
  local command = nil
  for _, token in ipairs(lex.tokens(dialect, table.concat(lines, "\n"))) do
    local set = token.kind == "meta" and delimiter(token.text)
    if set then
      command = set ~= ";" and vim.trim(token.text) or nil
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
  local starts, offset = {}, 1
  for index, line in ipairs(lines) do
    starts[index] = offset
    offset = offset + #line + 1
  end

  local tokens = {}
  for _, token in ipairs(lex.tokens(dialect, table.concat(lines, "\n"))) do
    if token.kind ~= "comment" then
      tokens[#tokens + 1] = token
    end
  end
  local terminators = statements.terminators(dialect, tokens)
  local ends, line = {}, 1
  for _, token in ipairs(tokens) do
    if terminators[token] then
      while starts[line + 1] and starts[line + 1] <= token.first do
        line = line + 1
      end
      ends[line - 1] = true
    end
  end

  local first, last = 0, #lines - 1
  for at = row - 1, 0, -1 do
    if ends[at] then
      first = at + 1
      break
    end
  end
  for at = row, #lines - 1 do
    if ends[at] then
      last = at
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

local ROW_SOURCES = { select = true, ["with"] = true, table = true, values = true }

local WRITES = { insert = true, update = true, delete = true, merge = true }

--- Returns how a single statement produces rows, or nil when it produces none.
---
--- "query" is a select, with, table, or values statement, which COPY accepts as
--- its argument. "returning" is an insert, update, delete, or merge with a
--- RETURNING clause, which some clients cannot write to a file. Text holding
--- more than one statement, or a client command such as psql's `\gset`,
--- returns nil, because a client command cannot go inside COPY. A mysql
--- `delimiter //` line is skipped, because the delimiter changes nothing
--- about the rows.
---@param dialect dbquery.Dialect
---@param sql string
---@return dbquery.RowKind|nil
function M.rowKind(dialect, sql)
  local setsDelimiter = dialect.commands and dialect.commands.delimiter
  for _, token in ipairs(lex.tokens(dialect, sql)) do
    if token.kind == "meta" and not (setsDelimiter and setsDelimiter(token.text)) then
      return nil
    end
  end
  local code = lex.code(lex.tokens(dialect, M.stripTerminator(dialect, sql)))
  if #statements.split(dialect, code) > 1 then
    return nil
  end

  local first = code[1] and code[1].kind == "word" and code[1].lower or ""
  local writes, returning = false, false
  for _, token in ipairs(code) do
    writes = writes or (token.kind == "word" and WRITES[token.lower] == true)
    returning = returning or lex.isWord(token, "returning")
  end

  if ROW_SOURCES[first] then
    -- Postgres refuses a data-modifying CTE inside COPY.
    if first == "with" and writes then
      return nil
    end
    return "query"
  end
  if WRITES[first] and returning then
    return "returning"
  end
  return nil
end

return M
