--[[
The copy of each catalog saved to disk for the next session.
]]

local files = require("db-query.query.files")
local shape = require("db-query.catalog.shape")

local M = {}

--- The version of `dbquery.Catalog` a saved file holds. Raise it with every
--- change to the shape, and add the step from the old version to `UPGRADES`.
local VERSION = 2

--- Steps a saved catalog from the version it is keyed by to the next one.
--- Leave a version out, or return nil from its step, when the change needs
--- data only a fresh read has, and the saved file is discarded.
---@type table<integer, fun(catalog: table): table|nil>
local UPGRADES = {
  -- Version 2 added the fields of composite types, which the next read fills.
  [1] = function(catalog)
    return catalog
  end,
}

---@class dbquery.SavedCatalog
---@field version integer
---@field catalog dbquery.Catalog

--- Returns the catalog saved for `key` by an earlier session, upgraded to
--- `VERSION`, or nil when there is none or it cannot be used.
---@param key string
---@return dbquery.Catalog|nil
function M.load(key)
  local file = io.open(files.catalog(key), "r")
  if not file then
    return nil
  end
  local text = file:read("*a")
  file:close()
  local ok, saved = pcall(vim.json.decode, text, { luanil = { object = true } })
  if not (ok and type(saved) == "table" and type(saved.version) == "number" and saved.version <= VERSION) then
    return nil
  end
  local catalog, version = saved.catalog, saved.version
  while catalog and version < VERSION do
    local upgrade = UPGRADES[version]
    catalog = upgrade and upgrade(catalog)
    version = version + 1
  end
  if not catalog or shape.problem(catalog) then
    return nil
  end
  return catalog
end

--- Saves `catalog` for `key`, through a file of this nvim's own renamed into
--- place, so two nvims saving at once never leave a mixed file.
---@param key string
---@param catalog dbquery.Catalog
function M.save(key, catalog)
  local path = files.catalog(key)
  local function failed(err)
    vim.notify("db-query: cannot save the catalog to " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
  end

  ---@type dbquery.SavedCatalog
  local saved = { version = VERSION, catalog = catalog }
  local encoded, text = pcall(vim.json.encode, saved)
  if not encoded then
    return failed(text)
  end
  local partial = path .. "." .. vim.uv.os_getpid()
  local file, openErr = io.open(partial, "w")
  if not file then
    return failed(openErr)
  end
  local wrote, writeErr = file:write(text)
  local closed, closeErr = file:close()
  local renamed, renameErr = nil, writeErr or closeErr
  if wrote and closed then
    renamed, renameErr = vim.uv.fs_rename(partial, path)
  end
  if not renamed then
    os.remove(partial)
    failed(renameErr)
  end
end

return M
