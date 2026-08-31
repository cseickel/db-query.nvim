--[[
Connection sources for the database picker.

Reads from vim-dadbod-ui's connections.json and `g:dbs` by default. A custom
`connections` function in setup() replaces both sources.
]]

local M = {}

---@class dbquery.Connection
---@field name string
---@field url string

---@return string
local function connectionsPath()
  local location = vim.g.db_ui_save_location or "~/.local/share/db_ui"
  return vim.fn.expand(location) .. "/connections.json"
end

--- Appends valid entries (those with name and url strings) to `into`.
---@param into dbquery.Connection[]
---@param entries table
local function collect(into, entries)
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and type(entry.name) == "string" and type(entry.url) == "string" then
      table.insert(into, { name = entry.name, url = entry.url })
    end
  end
end

---@return dbquery.Connection[] connections
---@return string|nil err
local function fromFile()
  local path = connectionsPath()
  if vim.fn.filereadable(path) == 0 then
    return {}, nil
  end

  local read, lines = pcall(vim.fn.readfile, path)
  if not read then
    return {}, "could not read " .. path
  end

  local decoded, entries = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded or type(entries) ~= "table" then
    return {}, path .. " does not hold a json list of connections"
  end

  local connections = {}
  collect(connections, entries)
  return connections, nil
end

--- Reads connections from `g:dbs`, supporting both list and dict formats.
---@return dbquery.Connection[]
local function fromGlobal()
  local dbs = vim.g.dbs
  if type(dbs) ~= "table" then
    return {}
  end

  local connections = {}
  if dbs[1] ~= nil then
    collect(connections, dbs)
  else
    for name, url in pairs(dbs) do
      if type(name) == "string" and type(url) == "string" then
        table.insert(connections, { name = name, url = url })
      end
    end
    table.sort(connections, function(left, right)
      return left.name < right.name
    end)
  end
  return connections
end

--- Returns all connections for the picker.
---
--- When `configured` is provided (list or function), it replaces the default
--- sources entirely. An invalid `configured` returns an error rather than
--- falling back to defaults.
---
--- Without `configured`, connections come from the json file then `g:dbs`,
--- with duplicates (by name) skipped.
---@param configured dbquery.Connection[]|fun(): dbquery.Connection[]|nil
---@return dbquery.Connection[] connections
---@return string|nil err
function M.list(configured)
  if configured ~= nil then
    if type(configured) == "function" then
      local called, result = pcall(configured)
      if not called then
        return {}, "connections function failed: " .. tostring(result)
      end
      configured = result
    end

    if type(configured) ~= "table" then
      return {}, "connections is a " .. type(configured) .. ", not a list of connections"
    end

    local connections = {}
    collect(connections, configured)
    if #connections == 0 then
      return {}, "connections held no entry with both a name and a url"
    end
    return connections, nil
  end

  local connections, err = fromFile()
  if err then
    return {}, err
  end

  local taken = {}
  for _, connection in ipairs(connections) do
    taken[connection.name] = true
  end
  for _, connection in ipairs(fromGlobal()) do
    if not taken[connection.name] then
      taken[connection.name] = true
      table.insert(connections, connection)
    end
  end

  return connections, nil
end

return M
