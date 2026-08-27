--[[
Reading a statement well enough to know how it has to be run.

A single row-returning statement can be asked for as delimited text, which
opens as a table. Anything else has to be run for the client's own transcript.
]]

local M = {}

---@alias dbquery.Mode "export"|"script"

--- `sql` without the semicolon and space that end it.
---@param sql string
---@return string
function M.stripTerminator(sql)
  return (sql:gsub(";%s*$", ""))
end

--- `sql` without the comments it opens with, so the statement keyword is
--- first.
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

--- The first and last line of the statement `row` is in, and nil where that is
--- nothing but blank lines. Statements are separated by semicolons, and the
--- blank lines between two of them belong to neither.
---
--- A semicolon inside a string literal ends a statement here as it does in
--- `mode`, and two statements written on one line cannot be told apart,
--- because the line is what this counts in.
---@param lines string[] Every line of the buffer.
---@param row integer The line the cursor is on, as nvim counts lines.
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

-- Statements whose result is the table the csv export carries.
local ROW_SOURCES = { select = true, ["with"] = true, table = true, values = true }

-- A CTE ending in one of these writes rows instead of returning them, and
-- Postgres refuses to put it inside COPY.
local WRITES = { "insert", "update", "delete", "merge" }

--- Whether `sql` is the single row-returning statement the csv export can
--- carry, or a script to be run for its transcript. A semicolon inside a
--- string literal reads as a second statement, which costs the table and
--- gives the transcript instead.
---@param sql string
---@return dbquery.Mode
function M.mode(sql)
  local body = M.stripTerminator(sql)
  if body:find(";", 1, true) then
    return "script"
  end

  local head = uncommented(body)
  local first = (head:match("^%s*(%a+)") or ""):lower()
  if not ROW_SOURCES[first] then
    return "script"
  end

  if first == "with" then
    local lowered = body:lower()
    for _, word in ipairs(WRITES) do
      if lowered:find("%f[%w_]" .. word .. "%f[^%w_]") then
        return "script"
      end
    end
  end
  return "export"
end

return M
