--[[
Names every file the plugin writes, and deletes the ones it owns.
]]

local config = require("db-query.config")

local M = {}

local ROOT = vim.fn.stdpath("cache") .. "/db-query"
-- Named by nvim's pid, so `sweep` can tell when the nvim that wrote it exited.
local SESSION_DIR = ROOT .. "/" .. vim.fn.getpid()
local CATALOG_DIR = ROOT .. "/catalog"

--- The output directory `:DBOutputDir` set, nil until it sets one.
---@type string|nil
local sessionDirectory = nil

--- Counts staging files, so each run gets its own.
local stagingCount = 0

local EXTENSIONS = { csv = true, tsv = true, txt = true }

---@return string
function M.directory()
  return sessionDirectory or config.values.output_dir or SESSION_DIR
end

--- Returns the base name for output files from `bufName`, defaulting to "query".
---@param bufName string
---@return string
local function baseName(bufName)
  local name = vim.fn.fnamemodify(bufName, ":t:r")
  if name == "" then
    return "query"
  end
  return name
end

--- Creates the parent directory and opens `path` in `mode`, so the client's
--- shell redirect cannot fail. Returns false and shows an error when the path
--- cannot be written.
---@param path string
---@param mode "a"|"w"
---@return boolean
local function ready(path, mode)
  pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
  local file = io.open(path, mode)
  if not file then
    vim.notify("db-query: cannot write " .. path, vim.log.levels.ERROR)
    return false
  end
  file:close()
  return true
end

--- Returns the output path without extension.
---
--- Without `chosen`, returns `cwd/baseName(bufName)`. With `chosen`, resolves
--- relative paths from cwd. A trailing slash or existing directory appends the
--- base name (e.g., `-o ~/exports/` becomes `~/exports/bufname`).
---@param bufName string Full path of the sql buffer.
---@param chosen string|nil
---@return string
function M.destination(bufName, chosen)
  if not chosen then
    return vim.fs.joinpath(vim.fn.getcwd(), baseName(bufName))
  end

  local named = chosen:sub(-1) ~= "/"
  local fullPath = vim.fs.normalize(chosen)
  if not vim.startswith(fullPath, "/") then
    fullPath = vim.fs.joinpath(vim.fn.getcwd(), fullPath)
  end
  if named and vim.fn.isdirectory(fullPath) == 0 then
    return fullPath
  end
  return vim.fs.joinpath(fullPath, baseName(bufName))
end

--- Sets the output directory for this session. Files there are not auto-deleted.
--- An empty `path` resets to the configured default.
---@param path string
function M.setDirectory(path)
  local fullPath = path ~= "" and vim.fs.normalize(path) or nil
  if fullPath and not (pcall(vim.fn.mkdir, fullPath, "p") and vim.fn.isdirectory(fullPath) == 1) then
    return vim.notify("db-query: cannot write in " .. fullPath, vim.log.levels.ERROR)
  end

  sessionDirectory = fullPath
  vim.notify("db-query: output goes to " .. M.directory())
end

--- Returns the log for buffer `buf`, which every run of that buffer appends to,
--- or nil when it cannot be written. The buffer number names the directory,
--- since two buffers can share a base name, and the file keeps the readable
--- name for the window showing it.
---@param buf integer Buffer the query came from.
---@param bufName string Full path of the sql buffer.
---@return string|nil
function M.log(buf, bufName)
  local path = SESSION_DIR .. "/" .. buf .. "/" .. baseName(bufName) .. ".md"
  return ready(path, "a") and path or nil
end

--- Returns a fresh path under this nvim's cache directory, named without
--- whitespace, for a client that cannot write to the results path itself. Each
--- call returns a new name, so two runs writing to the same `-o` path never
--- share a staging file.
---@param extension string
---@return string
function M.staging(extension)
  pcall(vim.fn.mkdir, SESSION_DIR, "p")
  stagingCount = stagingCount + 1
  return string.format("%s/staging-%d.%s", SESSION_DIR, stagingCount, extension)
end

--- Returns the file that holds the DDL of the object `name` names, under a
--- directory for `connection`, since two databases can each hold a
--- `public.users`. Each part of `name` keeps letters, digits, `_`, and `-`,
--- and every other byte is percent-encoded.
---@param connection string Resolved url.
---@param name string[] The object's qualified name, one part each.
---@return string
function M.definition(connection, name)
  local parts = vim.tbl_map(function(part)
    return (part:gsub("[^%w_-]", function(char)
      return string.format("%%%02X", char:byte())
    end))
  end, name)
  local directory = SESSION_DIR .. "/definitions/" .. vim.fn.sha256(connection):sub(1, 12)
  pcall(vim.fn.mkdir, directory, "p")
  return directory .. "/" .. table.concat(parts, ".") .. ".sql"
end

--- Returns true when the plugin should delete `path` once the buffer that
--- produced it is gone. A file the user named or sent to a directory of their
--- own is theirs to keep.
---@param path string
---@return boolean
function M.owns(path)
  return sessionDirectory == nil and config.values.output_cleanup and vim.startswith(path, M.directory() .. "/")
end

--- Returns a results file path, ready for writing, or nil on error or a
--- declined overwrite. With `chosen`, it is that path, asking before writing
--- over a file there, with its extension replaced by `extension` when it has
--- one a results file can have. Without `chosen`, it is the next unused
--- `name-N.extension` in the output directory.
---@param bufName string Full path of the sql buffer.
---@param extension string File extension: csv, tsv, or txt.
---@param chosen string|nil
---@return string|nil
function M.path(bufName, extension, chosen)
  if chosen then
    local fullPath = M.destination(bufName, chosen)
    if vim.startswith(fullPath, ROOT .. "/") then
      return vim.notify(
        "db-query: nothing may be written in " .. ROOT .. ", which is cleared up on startup",
        vim.log.levels.ERROR
      )
    end
    local stem = EXTENSIONS[vim.fn.fnamemodify(fullPath, ":e")] and vim.fn.fnamemodify(fullPath, ":r") or fullPath
    local path = stem .. "." .. extension
    if vim.uv.fs_stat(path) and vim.fn.confirm(path .. " exists.", "&Overwrite\n&Cancel", 2) ~= 1 then
      return nil
    end
    return ready(path, "w") and path or nil
  end

  local dir = M.directory()
  local name = baseName(bufName)
  local numbered = "^" .. vim.pesc(name) .. "%-(%d+)%."
  local highest = 0
  for entry in vim.fs.dir(dir) do
    local number = tonumber(entry:match(numbered))
    if number and number > highest then
      highest = number
    end
  end
  local path = string.format("%s/%s-%d.%s", dir, name, highest + 1, extension)
  return ready(path, "w") and path or nil
end

---@param pid integer
---@return boolean
local function alive(pid)
  local called, result = pcall(vim.uv.kill, pid, 0)
  return called and result == 0
end

--- Returns the file a database's catalog is saved in between sessions, named
--- by a hash of `key`. The directory is created readable by this user alone,
--- since a catalog names every table and column of a database.
---@param key string
---@return string
function M.catalog(key)
  pcall(vim.fn.mkdir, CATALOG_DIR, "p", 448)
  return CATALOG_DIR .. "/" .. vim.fn.sha256(key) .. ".json"
end

--- Deletes output directories for nvims that have exited, and the partly
--- written catalogs they left, named `<hash>.json.<pid>`.
function M.sweep()
  if vim.fn.isdirectory(ROOT) == 0 then
    return
  end
  for name, kind in vim.fs.dir(ROOT) do
    local pid = tonumber(name)
    if kind == "directory" and pid and not alive(pid) then
      vim.fn.delete(ROOT .. "/" .. name, "rf")
    end
  end
  if vim.fn.isdirectory(CATALOG_DIR) == 0 then
    return
  end
  for name in vim.fs.dir(CATALOG_DIR) do
    local pid = tonumber(name:match("%.json%.(%d+)$"))
    if pid and not alive(pid) then
      os.remove(CATALOG_DIR .. "/" .. name)
    end
  end
end

return M
