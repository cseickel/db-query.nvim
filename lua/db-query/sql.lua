--[[
SQL parsing for output routing and for the statement the cursor is in.

Determines whether a statement returns rows, and if so whether it can be
wrapped in COPY. A statement that returns no rows writes nothing but its
transcript, which belongs in the log.

Every semicolon here is read off a copy with the comments blanked out, so a
`;` a comment wrote neither splits a statement nor sends its rows to the log.
]]

local M = {}

---@alias dbquery.RowKind "query"|"returning"

local OPENERS = { "--", "/*", "'", '"' }

--- Returns where the next comment or quote starts at or after `index`, and
--- which one it is.
---@param sql string
---@param index integer
---@return integer|nil at
---@return string|nil opener
local function opening(sql, index)
  local at, opener = math.huge, nil
  for _, candidate in ipairs(OPENERS) do
    local found = sql:find(candidate, index, true)
    if found and found < at then
      at, opener = found, candidate
    end
  end
  return opener and at or nil, opener
end

--- Returns `sql` with every comment blanked out, keeping the newlines, so a
--- caller can look for a semicolon without finding one a comment wrote. Every
--- byte keeps its position, and the query that runs is still the original text.
---
--- A string literal is stepped over rather than blanked, so the `--` in
--- `select '--'` opens no comment. A `;` inside one still reads as a
--- terminator, which is the limitation the semicolon search always had.
---@param sql string
---@return string
local function uncommented(sql)
  local pieces = {}
  local copied, index = 1, 1

  while true do
    local at, opener = opening(sql, index)
    if not at then
      break
    end

    if opener == "'" or opener == '"' then
      local closing = sql:find(opener, at + 1, true)
      index = closing and closing + 1 or #sql + 1
    else
      local stop
      if opener == "--" then
        stop = sql:find("\n", at, true) or #sql + 1
      else
        local closing = sql:find("*/", at, true)
        stop = closing and closing + 2 or #sql + 1
      end

      table.insert(pieces, sql:sub(copied, at - 1))
      table.insert(pieces, (sql:sub(at, stop - 1):gsub("[^\n]", " ")))
      copied, index = stop, stop
    end
  end

  table.insert(pieces, sql:sub(copied))
  return table.concat(pieces)
end

--- Removes the statement's trailing semicolon, even when a comment follows it.
--- The comment itself stays, because the caller may wrap what comes back in
--- `COPY (...)`, where a semicolon is a syntax error.
---@param sql string
---@return string
function M.stripTerminator(sql)
  local at = uncommented(sql):find(";%s*$")
  if not at then
    return sql
  end
  return sql:sub(1, at - 1) .. sql:sub(at + 1)
end

---@param line string|nil
---@return boolean
local function blank(line)
  return line == nil or line:match("^%s*$") ~= nil
end

--- Returns the line span of the statement containing `row`, or nil for blank
--- lines. Uses semicolons as statement separators, reading them off a copy with
--- the comments blanked out, so only a `;` inside a string literal still ends a
--- statement it did not mean to.
---@param lines string[]
---@param row integer 0-based line number.
---@return [integer, integer]|nil
function M.statementAt(lines, row)
  local scan = vim.split(uncommented(table.concat(lines, "\n")), "\n")
  local first, last = 0, #lines - 1

  for line = row - 1, 0, -1 do
    if scan[line + 1]:find(";", 1, true) then
      first = line + 1
      break
    end
  end
  for line = row, #lines - 1 do
    if scan[line + 1]:find(";", 1, true) then
      last = line
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

---@param lowered string
---@param word string
---@return boolean
local function mentions(lowered, word)
  return lowered:find("%f[%w_]" .. word .. "%f[^%w_]") ~= nil
end

--- Returns how a single statement produces rows, or nil when it produces none.
---
--- "query" is a select, with, table, or values statement, which COPY accepts as
--- its argument. "returning" is an insert, update, delete, or merge with a
--- RETURNING clause, which some clients cannot write to a file.
---@param sql string
---@return dbquery.RowKind|nil
function M.rowKind(sql)
  local body = uncommented(M.stripTerminator(sql))
  if body:find(";", 1, true) then
    return nil
  end

  local lowered = body:lower()
  local first = lowered:match("^%s*(%a+)") or ""

  if ROW_SOURCES[first] then
    if first == "with" then
      for word in pairs(WRITES) do
        -- Postgres refuses a data-modifying CTE inside COPY.
        if mentions(lowered, word) then
          return nil
        end
      end
    end
    return "query"
  end

  if WRITES[first] and mentions(lowered, "returning") then
    return "returning"
  end
  return nil
end

return M
