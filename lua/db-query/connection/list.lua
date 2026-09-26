--[[
The connections the picker offers.

Read from vim-dadbod-ui's connections.json and `g:dbs` by default. A
`connections` list or function in setup() replaces both sources.
]]

local config = require("db-query.config")

local M = {}

---@class dbquery.Connection
---@field name string
---@field url string

--- Appends each entry that has a string name and url.
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
  local location = vim.g.db_ui_save_location or "~/.local/share/db_ui"
  local path = vim.fn.expand(location) .. "/connections.json"
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
--- The `connections` setting, a list or a function returning one, replaces the
--- default sources entirely, and an invalid one returns an error rather than
--- falling back to them. Without it, connections come from the json file then
--- `g:dbs`, skipping a name already listed.
---@return dbquery.Connection[] connections
---@return string|nil err
function M.list()
  local configured = config.values.connections
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

  local seenNames = {}
  for _, connection in ipairs(connections) do
    seenNames[connection.name] = true
  end
  for _, connection in ipairs(fromGlobal()) do
    if not seenNames[connection.name] then
      seenNames[connection.name] = true
      table.insert(connections, connection)
    end
  end

  return connections, nil
end

--- Returns the connection called `name` from the list `M.list` returns, or nil
--- and why not.
---@param name string
---@return dbquery.Connection|nil connection
---@return string|nil err
function M.named(name)
  local connections, err = M.list()
  if err then
    return nil, err
  end
  for _, connection in ipairs(connections) do
    if connection.name == name then
      return connection, nil
    end
  end
  return nil, "no connection named " .. name
end

return M
