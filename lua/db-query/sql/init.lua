--[[
SQL parsing for output routing and for the statement the cursor is in.

Determines whether a statement returns rows, and if so whether it can be
wrapped in COPY. A statement that returns no rows writes nothing but its
transcript, which belongs in the log.

Every function here reads tokens from `sql.lex`, so a semicolon or keyword
inside a string, a comment, or a dollar-quoted body is never mistaken for
code.
]]

local lex = require("db-query.sql.lex")

local M = {}

---@alias dbquery.RowKind "query"|"returning"

--- Removes the statement's trailing semicolon, which is a syntax error inside
--- `COPY (...)`. A comment after the semicolon stays.
---@param sql string
---@return string
function M.stripTerminator(sql)
  local code = lex.code(lex.tokens(sql))
  local last = code[#code]
  if not (last and last.kind == ";") then
    return sql
  end
  return sql:sub(1, last.first - 1) .. sql:sub(last.first + 1)
end

---@param line string|nil
---@return boolean
local function blank(line)
  return line == nil or line:match("^%s*$") ~= nil
end

--- Returns the line span of the statement containing `row`, or nil for blank
--- lines. A line holding a terminator, as `lex.terminators` defines one, is
--- the last line of its statement, so statements sharing a line are returned
--- together.
---@param lines string[]
---@param row integer 0-based line number.
---@return [integer, integer]|nil
function M.statementAt(lines, row)
  local starts, offset = {}, 1
  for index, line in ipairs(lines) do
    starts[index] = offset
    offset = offset + #line + 1
  end

  local tokens = {}
  for _, token in ipairs(lex.tokens(table.concat(lines, "\n"))) do
    if token.kind ~= "comment" then
      tokens[#tokens + 1] = token
    end
  end
  local terminators = lex.terminators(tokens)
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
--- more than one statement, or a psql backslash command, returns nil.
---@param sql string
---@param scheme string The connection's url scheme. A backslash starts a psql command only for postgres, and is an escape inside a mysql string.
---@return dbquery.RowKind|nil
function M.rowKind(sql, scheme)
  if scheme == "postgres" or scheme == "postgresql" then
    for _, token in ipairs(lex.tokens(sql)) do
      -- A psql command cannot go inside COPY, so the script runs as written.
      if token.kind == "meta" then
        return nil
      end
    end
  end
  local code = lex.code(lex.tokens(M.stripTerminator(sql)))
  if #lex.statements(code) > 1 then
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
