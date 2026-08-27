--[[
The files clients write their output to.

A file this module names goes under the cache directory rather than through
vim.fn.tempname, because nvim's temp directory is under /tmp, and a /tmp on
tmpfs is memory. A result set large enough to be worth exporting would be held
in memory twice over. Each nvim writes into a directory named for its own pid,
which is what lets one nvim clear up after the ones that exited without doing
it themselves.

`-o` names a file instead, and that one is the user's: it is written where they
said, kept when the window showing it closes, and never swept. `owns` is the
question everything else asks to tell the two apart.
]]

local M = {}

local ROOT = vim.fn.stdpath("cache") .. "/db-query"
local MINE = ROOT .. "/" .. vim.fn.getpid()

-- How many files each source buffer has been given, so a second run of the
-- same query does not write over the first while it is still on screen.
---@type table<string, integer>
local written = {}

--- What output taken from `srcName` is called, before the number and the
--- extension. An unnamed buffer has no name to take, and its output is called
--- what it holds.
---@param srcName string
---@return string
local function baseName(srcName)
  local name = vim.fn.fnamemodify(srcName, ":t:r")
  if name == "" then
    return "query"
  end
  return name
end

--- Where output from `srcName` goes, before the extension: the path the user
--- asked for, and without one the name of that buffer in the working directory,
--- which is what the prompt offers.
---
--- A relative path is taken from the working directory, and a path that names a
--- directory takes the name of the buffer, so `-o ~/exports/` is a place to put
--- the output rather than a hidden file called `.csv`.
---@param srcName string The full path of the buffer the sql came from.
---@param chosen string|nil
---@return string
function M.destination(srcName, chosen)
  if not chosen then
    return vim.fs.joinpath(vim.fn.getcwd(), baseName(srcName))
  end

  local directory = chosen:sub(-1) == "/"
  local full = vim.fs.normalize(chosen)
  if not vim.startswith(full, "/") then
    full = vim.fs.joinpath(vim.fn.getcwd(), full)
  end
  if directory or vim.fn.isdirectory(full) == 1 then
    return vim.fs.joinpath(full, baseName(srcName))
  end
  return full
end

--- Whether this plugin made `path` up, which is what makes it ours to delete.
--- A file the user named is theirs, and outlives the window that showed it.
---@param path string
---@return boolean
function M.owns(path)
  return vim.startswith(path, ROOT .. "/")
end

--- The file `full` names, with the extension the client is going to write, made
--- empty and ready for it. Nil for a place it cannot be written, or an
--- overwrite that was turned down.
---
--- Emptying it here is what tells the caller now, rather than through whatever
--- the client's redirect does with a path it cannot open, and it is what makes
--- the size of the file mean this run's output rather than the last one's.
---@param full string The path and base name the user asked for.
---@param extension string
---@return string|nil
local function named(full, extension)
  if M.owns(full) then
    return vim.notify(
      "db-query: nothing may be written in " .. ROOT .. ", which is cleared up on startup",
      vim.log.levels.ERROR
    )
  end

  local suffix = "." .. extension
  local path = vim.endswith(full, suffix) and full or (full .. suffix)
  if vim.uv.fs_stat(path) and vim.fn.confirm(path .. " exists.", "&Overwrite\n&Cancel", 2) ~= 1 then
    return nil
  end

  pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
  local file = io.open(path, "w")
  if not file then
    return vim.notify("db-query: cannot write " .. path, vim.log.levels.ERROR)
  end
  file:close()
  return path
end

--- A file for one query's output. `chosen` is the path and base name the user
--- asked for, and without one the file is named for the buffer the sql came
--- from and is unused, so a second run of the same query does not write over
--- the first while it is still on screen.
---
--- The extension is the client's either way, because what the file holds is the
--- client's to decide and a csv named `.txt` is read by nothing. A `chosen` that
--- already ends in that extension keeps the one it has.
---
--- Nil for a file the user asked for and cannot have, already reported or
--- turned down, so the caller runs nothing.
---@param srcName string The full path of the buffer the sql came from.
---@param extension string What the client writes: csv, tsv, or log.
---@param chosen string|nil
---@return string|nil
function M.path(srcName, extension, chosen)
  if chosen then
    return named(M.destination(srcName, chosen), extension)
  end

  vim.fn.mkdir(MINE, "p")
  local name = baseName(srcName)
  written[name] = (written[name] or 0) + 1
  return string.format("%s/%s-%d.%s", MINE, name, written[name], extension)
end

--- Whether a process is still running, which is what makes its output worth
--- keeping.
---@param pid integer
---@return boolean
local function alive(pid)
  local called, result = pcall(vim.uv.kill, pid, 0)
  return called and result == 0
end

--- Removes what nvims that are no longer running left behind.
---
--- A file is deleted when the buffer showing it is wiped, so what this finds is
--- the output of an nvim that was killed, or that exited with a result still on
--- screen. Sweeping at startup rather than at exit is what covers the first of
--- those.
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
