--[[
Output file paths and cleanup.

Files are written to a subdirectory of nvim's cache by default, named by nvim's
pid. On startup, sweep() removes directories for nvims that have exited.

The `output_dir` config and `:DBOutputDir` command override the path. Files in
a user-specified directory are not auto-deleted.
]]

local config = require("db-query.config")

local M = {}

local ROOT = vim.fn.stdpath("cache") .. "/db-query"
local MINE = ROOT .. "/" .. vim.fn.getpid()

---@type string|nil
local asked = nil

local EXTENSIONS = { csv = true, tsv = true, log = true }

---@return string
function M.directory()
  return asked or config.values.output_dir or MINE
end

---@return boolean
local function clearing()
  return asked == nil and config.values.output_cleanup
end

--- Returns the base name for output files from `srcName`, defaulting to "query".
---@param srcName string
---@return string
local function baseName(srcName)
  local name = vim.fn.fnamemodify(srcName, ":t:r")
  if name == "" then
    return "query"
  end
  return name
end

--- Creates the parent directory and touches `path`. Returns false and shows an
--- error when the path cannot be written.
---@param path string
---@return boolean
local function ready(path)
  pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
  local file = io.open(path, "w")
  if not file then
    vim.notify("db-query: cannot write " .. path, vim.log.levels.ERROR)
    return false
  end
  file:close()
  return true
end

--- Returns the output path without extension.
---
--- Without `chosen`, returns `cwd/baseName(srcName)`. With `chosen`, resolves
--- relative paths from cwd. A trailing slash or existing directory appends the
--- base name (e.g., `-o ~/exports/` becomes `~/exports/bufname`).
---@param srcName string Full path of the source buffer.
---@param chosen string|nil
---@return string
function M.destination(srcName, chosen)
  if not chosen then
    return vim.fs.joinpath(vim.fn.getcwd(), baseName(srcName))
  end

  local named = chosen:sub(-1) ~= "/"
  local full = vim.fs.normalize(chosen)
  if not vim.startswith(full, "/") then
    full = vim.fs.joinpath(vim.fn.getcwd(), full)
  end
  if named and vim.fn.isdirectory(full) == 0 then
    return full
  end
  return vim.fs.joinpath(full, baseName(srcName))
end

--- Sets the output directory for this session. Files there are not auto-deleted.
--- An empty `path` resets to the configured default.
---@param path string
function M.setDirectory(path)
  local full = path ~= "" and vim.fs.normalize(path) or nil
  if full and not (pcall(vim.fn.mkdir, full, "p") and vim.fn.isdirectory(full) == 1) then
    return vim.notify("db-query: cannot write in " .. full, vim.log.levels.ERROR)
  end

  asked = full
  vim.notify("db-query: output goes to " .. M.directory())
end

--- Returns true when `path` should be deleted when its window closes.
---@param path string
---@return boolean
function M.owns(path)
  return clearing() and vim.startswith(path, M.directory() .. "/")
end

--- Returns `full` with `extension`, replacing any existing output extension.
---@param full string
---@param extension string
---@return string
local function withExtension(full, extension)
  if EXTENSIONS[vim.fn.fnamemodify(full, ":e")] then
    return vim.fn.fnamemodify(full, ":r") .. "." .. extension
  end
  return full .. "." .. extension
end

--- Returns the path ready for writing, or nil on error or cancelled overwrite.
---@param full string Path and base name for output.
---@param extension string
---@return string|nil
local function namedFile(full, extension)
  if vim.startswith(full, ROOT .. "/") then
    return vim.notify(
      "db-query: nothing may be written in " .. ROOT .. ", which is cleared up on startup",
      vim.log.levels.ERROR
    )
  end

  local path = withExtension(full, extension)
  if vim.uv.fs_stat(path) and vim.fn.confirm(path .. " exists.", "&Overwrite\n&Cancel", 2) ~= 1 then
    return nil
  end
  return ready(path) and path or nil
end

--- Returns the next available number for `name-N.ext` files in `dir`.
---@param dir string
---@param name string
---@return integer
local function unused(dir, name)
  local pattern = "^" .. vim.pesc(name) .. "%-(%d+)%."
  local highest = 0
  for entry in vim.fs.dir(dir) do
    local number = tonumber(entry:match(pattern))
    if number and number > highest then
      highest = number
    end
  end
  return highest + 1
end

--- Returns an output file path, ready for writing.
---
--- With `chosen`, uses that path (prompting for overwrite if it exists).
--- Without `chosen`, generates a numbered path in the output directory.
---
--- Returns nil on error or cancelled overwrite.
---@param srcName string Full path of the source buffer.
---@param extension string File extension: csv, tsv, or log.
---@param chosen string|nil
---@return string|nil
function M.path(srcName, extension, chosen)
  if chosen then
    return namedFile(M.destination(srcName, chosen), extension)
  end

  local dir = M.directory()
  local name = baseName(srcName)
  local path = string.format("%s/%s-%d.%s", dir, name, unused(dir, name), extension)
  return ready(path) and path or nil
end

---@param pid integer
---@return boolean
local function alive(pid)
  local called, result = pcall(vim.uv.kill, pid, 0)
  return called and result == 0
end

--- Deletes output directories for nvims that have exited.
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
end

return M
