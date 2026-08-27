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
