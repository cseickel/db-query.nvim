--[[
The `@db-query` modeline, a line comment that names the connection a sql file
runs against:

    -- @db-query connection=[rva-3-dev]

It is read from the first and last REACH lines, as vim reads its own
modelines, so a `@db-query` inside a query's comment is not taken for one. The
key can be any start of `connection`, so `c=` and `conn=` work too, and the
brackets are needed only when the name holds a space.
]]

local M = {}

local REACH = 5

local MARKER = "^%s*%-%-%s*@db%-query%s()"
local KEY = "connection"

---@class dbquery.Modeline
---@field row integer 0-based line the modeline is on.
---@field text string The whole line.
---@field connection string|nil The name it gives, nil when it gives none.

--- Returns the connection name set in `line` after column `index`, with the
--- first and last column of its value, brackets included.
---@param line string
---@param index integer
---@return string|nil name
---@return integer first
---@return integer last
local function setting(line, index)
  while true do
    local _, equals, key = line:find("%f[%w_]([%w_]+)=", index)
    if not key then
      return nil, 0, 0
    end

    local first, last, value = equals + 1, nil, nil
    if line:sub(first, first) == "[" then
      last = line:find("]", first + 1, true)
      if not last then
        return nil, 0, 0
      end
      value = line:sub(first + 1, last - 1)
    else
      value = line:match("^%S*", first)
      last = first + #value - 1
    end

    value = vim.trim(value)
    if vim.startswith(KEY, key) and value ~= "" then
      return value, first, last
    end
    index = last + 1
  end
end

--- Returns the modeline in `buf`, or nil when it has none. When there is more
--- than one, the one nearest the end wins.
---@param buf integer
---@return dbquery.Modeline|nil
function M.find(buf)
  local count = vim.api.nvim_buf_line_count(buf)
  local found = nil

  ---@param first integer
  ---@param last integer
  local function scan(first, last)
    for offset, line in ipairs(vim.api.nvim_buf_get_lines(buf, first, last, false)) do
      local index = line:match(MARKER)
      if index then
        found = { row = first + offset - 1, text = line, connection = (setting(line, index)) }
      end
    end
  end

  scan(0, math.min(REACH, count))
  scan(math.max(REACH, count - REACH), count)
  return found
end

--- Replaces the connection `modeline` names with `name`, keeping the key as
--- written and the rest of the line. Leaves the buffer modified and unsaved.
---@param buf integer
---@param modeline dbquery.Modeline Found in `buf`, naming a connection.
---@param name string
function M.rewrite(buf, modeline, name)
  local text = modeline.text
  local _, first, last = setting(text, text:match(MARKER))
  text = text:sub(1, first - 1) .. "[" .. name .. "]" .. text:sub(last + 1)
  vim.api.nvim_buf_set_lines(buf, modeline.row, modeline.row + 1, false, { text })
end

return M
