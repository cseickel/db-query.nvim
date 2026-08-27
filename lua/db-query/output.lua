--[[
The files clients write their output to.

Output goes under the cache directory rather than through vim.fn.tempname,
because nvim's temp directory is under /tmp, and a /tmp on tmpfs is memory. A
result set large enough to be worth exporting would be held in memory twice
over.

Each nvim writes into a directory named for its own pid, which is what lets one
nvim clear up after the ones that exited without doing it themselves.
]]

local M = {}

local ROOT = vim.fn.stdpath("cache") .. "/db-query"
local MINE = ROOT .. "/" .. vim.fn.getpid()

-- How many files each source buffer has been given, so a second run of the
-- same query does not write over the first while it is still on screen.
---@type table<string, integer>
local written = {}

--- A file for one query's output, named for the buffer the sql came from and
--- unused. An unnamed buffer has no name to take, and its output is called
--- what it holds.
---@param srcName string The full path of the buffer the sql came from.
---@param extension string What the client writes: csv, tsv, or log.
---@return string
function M.path(srcName, extension)
  vim.fn.mkdir(MINE, "p")
  local name = vim.fn.fnamemodify(srcName, ":t:r")
  if name == "" then
    name = "query"
  end
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
