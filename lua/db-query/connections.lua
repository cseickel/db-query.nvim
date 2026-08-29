--[[
Where the list of databases comes from.

vim-dadbod-ui keeps its connections in a json file, and this module reads that
same file rather than introducing a second list, so a config that already names
its databases needs no new configuration. `g:dbs` is read too, because that is
where vim-dadbod itself looks.

Nothing here writes. A connection is added by editing the file, or by giving
`setup` a `connections` function that answers from somewhere else entirely.
]]

local M = {}

---@class dbquery.Connection
---@field name string
---@field url string

--- The file vim-dadbod-ui reads, wherever the user has pointed it.
---@return string
local function connectionsPath()
  local location = vim.g.db_ui_save_location or "~/.local/share/db_ui"
  return vim.fn.expand(location) .. "/connections.json"
end

--- Appends every well-formed entry of `entries` to `into`, skipping any that
--- does not name both a connection and a url.
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

--- `g:dbs` is written either as a list of name and url pairs or as a table of
--- name to url, and vim-dadbod reads both, so both are read here.
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

--- Every connection the chooser offers.
---
--- `configured` replaces both other sources when the user supplies one, as a
--- list or as a function returning one. A `configured` that is not a list is an
--- error rather than a reason to read the file, because falling back would
--- offer a list the user did not ask for.
---
--- Otherwise a name already taken is skipped, so the file wins over `g:dbs` and
--- neither can hide the other's entries behind a duplicate.
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
