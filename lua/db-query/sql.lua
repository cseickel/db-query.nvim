--[[
SQL parsing for output routing.

Determines whether a statement returns rows, and if so whether it can be
wrapped in COPY. A statement that returns no rows writes nothing but its
transcript, which belongs in the log.
]]

local M = {}

---@alias dbquery.RowKind "query"|"returning"

--- Removes trailing semicolon and whitespace.
---@param sql string
---@return string
function M.stripTerminator(sql)
  return (sql:gsub(";%s*$", ""))
end

--- Strips leading comments to expose the first keyword.
---@param sql string
---@return string
local function uncommented(sql)
  local head = sql
  while true do
    local rest = head:gsub("^%s*%-%-[^\n]*\n", ""):gsub("^%s*/%*.-%*/", "")
    if rest == head then
      return head
    end
    head = rest
  end
end

---@param line string|nil
---@return boolean
local function blank(line)
  return line == nil or line:match("^%s*$") ~= nil
end

--- Returns the line span of the statement containing `row`, or nil for blank
--- lines. Uses semicolons as statement separators (does not parse string
--- literals).
---@param lines string[]
---@param row integer 0-based line number.
---@return [integer, integer]|nil
function M.statementAt(lines, row)
  local first, last = 0, #lines - 1

  for line = row - 1, 0, -1 do
    if lines[line + 1]:find(";", 1, true) then
      first = line + 1
      break
    end
  end
  for line = row, #lines - 1 do
    if lines[line + 1]:find(";", 1, true) then
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
  local body = M.stripTerminator(sql)
  if body:find(";", 1, true) then
    return nil
  end

  local lowered = body:lower()
  local first = uncommented(lowered):match("^%s*(%a+)") or ""

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
