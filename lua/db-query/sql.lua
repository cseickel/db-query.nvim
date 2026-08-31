--[[
SQL parsing for execution mode detection.

Determines whether sql can be exported as csv (single row-returning statement)
or must run as a script (multiple statements, DDL, DML).
]]

local M = {}

---@alias dbquery.Mode "export"|"script"

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

-- CTEs ending in these cannot be wrapped in COPY.
local WRITES = { "insert", "update", "delete", "merge" }

--- Returns true for a single row-returning statement, false otherwise.
---@param sql string
---@return boolean
function M.canExport(sql)
  local body = M.stripTerminator(sql)
  if body:find(";", 1, true) then
    return false
  end

  local head = uncommented(body)
  local first = (head:match("^%s*(%a+)") or ""):lower()
  if not ROW_SOURCES[first] then
    return false
  end

  if first == "with" then
    local lowered = body:lower()
    for _, word in ipairs(WRITES) do
      if lowered:find("%f[%w_]" .. word .. "%f[^%w_]") then
        return false
      end
    end
  end
  return true
end

return M
