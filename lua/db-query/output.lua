--[[
Choosing the file a client writes its output to, and deciding who deletes it.

Output does not go through `vim.fn.tempname`, because nvim's temp directory is
under /tmp, and a /tmp on tmpfs is memory. A result set large enough to be worth
exporting would then be held in memory twice over.

`directory` answers with the first of these that applies: the path
`:DBOutputDir` was given, the `output_dir` setting, or a directory named for
this nvim's pid under the cache. That pid is what lets one nvim clear up after
another that exited without doing it itself.

`owns` says whether this plugin deletes a file with the window that showed it.
A file in the cache always goes, a file in `output_dir` goes unless
`output_cleanup` is off, and a file in a directory named by `:DBOutputDir` never
goes, since naming a directory while you work is how you say you are keeping
what lands in it.
]]

local config = require("db-query.config")

local M = {}

local ROOT = vim.fn.stdpath("cache") .. "/db-query"
local MINE = ROOT .. "/" .. vim.fn.getpid()

-- Where output goes for the rest of the session, once a command has said so.
---@type string|nil
local asked = nil

-- What a client is ever asked to write, which is what makes an extension one
-- this plugin put there and may take back.
local EXTENSIONS = { csv = true, tsv = true, log = true }

--- Where output is written.
---@return string
function M.directory()
  return asked or config.values.output_dir or MINE
end

--- Whether what is written to `M.directory()` is this plugin's to clear up.
---@return boolean
local function clearing()
  return asked == nil and config.values.output_cleanup
end

--- What output taken from `srcName` is called, before the number and the
--- extension. An unnamed buffer has no name to take, so its output is called
--- `query`.
---@param srcName string
---@return string
local function baseName(srcName)
  local name = vim.fn.fnamemodify(srcName, ":t:r")
  if name == "" then
    return "query"
  end
  return name
end

--- Makes the directory `path` is in and empties the file, so that the client
--- has somewhere to write. Creating the file here is what reports an unwritable
--- path clearly, rather than leaving it to whatever a shell redirect does with a
--- path it cannot open. Emptying it also means its size is this run's output.
---
--- False and reported when the file cannot be written.
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

--- Where output is written from now on, until nvim exits, and nothing written
--- there is deleted. An empty `path` puts it back to what `setup` was given.
---
--- The directory is made here rather than at the first query, so a path that
--- cannot be created is reported while the user is still looking at the prompt.
---@param path string
function M.setDirectory(path)
  local full = path ~= "" and vim.fs.normalize(path) or nil
  if full and not (pcall(vim.fn.mkdir, full, "p") and vim.fn.isdirectory(full) == 1) then
    return vim.notify("db-query: cannot write in " .. full, vim.log.levels.ERROR)
  end

  asked = full
  vim.notify("db-query: output goes to " .. M.directory())
end

--- Whether this plugin deletes `path` with the window that showed it, which is
--- a question about the directory output is going to rather than about who
--- named the file.
---@param path string
---@return boolean
function M.owns(path)
  return clearing() and vim.startswith(path, M.directory() .. "/")
end

--- `full` with the extension the client is going to write. An extension a
--- client would have written is replaced rather than added to, so `-o
--- report.csv` on a query that writes a transcript is `report.log`.
---@param full string
---@param extension string
---@return string
local function withExtension(full, extension)
  if EXTENSIONS[vim.fn.fnamemodify(full, ":e")] then
    return vim.fn.fnamemodify(full, ":r") .. "." .. extension
  end
  return full .. "." .. extension
end

--- The file `full` names, with the client's extension, ready to be written.
--- Nil for a place it cannot be written, or an overwrite that was turned down.
---@param full string The path and base name the output is to be written to.
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

--- The number to give the next file called `name` in `dir`, which is one past
--- the highest already there. Output kept beside older output does not write
--- over it, and a directory that is cleared up starts again at one by itself.
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

--- A file for one query's output. `chosen` is the path and base name the query
--- asked for, and without one the file is named for the buffer the sql came
--- from, numbered so that running the same query again does not write over a
--- result still on screen.
---
--- The extension is the client's either way, because what the file holds is the
--- client's to decide and a csv named `.txt` is read by nothing.
---
--- Nil for a file that cannot be written or an overwrite that was turned down,
--- already reported or asked about, so the caller runs nothing.
---@param srcName string The full path of the buffer the sql came from.
---@param extension string What the client writes: csv, tsv, or log.
---@param chosen string|nil
---@return string|nil
function M.path(srcName, extension, chosen)
  if chosen then
    return namedFile(M.destination(srcName, chosen), extension)
  end

  -- The directory is made by `ready`, which reports what it cannot make.
  local dir = M.directory()
  local name = baseName(srcName)
  local path = string.format("%s/%s-%d.%s", dir, name, unused(dir, name), extension)
  return ready(path) and path or nil
end

--- Whether a process is still running, which is what makes its output worth
--- keeping.
---@param pid integer
---@return boolean
local function alive(pid)
  local called, result = pcall(vim.uv.kill, pid, 0)
  return called and result == 0
end

--- Removes what nvims that are no longer running left behind in the cache.
---
--- A file is deleted when the buffer showing it is wiped, so what this finds is
--- the output of an nvim that was killed, or that exited with a result still on
--- screen. Sweeping at startup rather than at exit is what covers the first of
--- those. A directory of the user's has no pid in its name and is never walked.
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
