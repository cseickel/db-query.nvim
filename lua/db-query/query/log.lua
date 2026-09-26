--[[
How a sql buffer's log reads. Every run of the buffer appends to one markdown
file: the sql it ran, what the client printed, and how it ended.
]]

local files = require("db-query.query.files")
local runStatus = require("db-query.query.status")

---@class dbquery.Log
---@field path string The file every run of one sql buffer appends to.
---@field runs integer Runs begun so far, which is what numbers each one.
local Log = {}
Log.__index = Log

--- The output fence is longer than the sql fence, so neither the sql nor client
--- output can close the block the client writes into. A cancelled run still
--- writing while its replacement begins leaves a block open until the next run
--- closes it.
local SQL_FENCE = "```"
local OUTPUT_FENCE_OPEN = "~~~~ bash\n"
local OUTPUT_FENCE_CLOSE = "~~~~"
local SEPARATOR = string.rep("-", 80)

---@param path string
---@param text string
local function append(path, text)
  local file = io.open(path, "a")
  if file then
    file:write(text)
    file:close()
  end
end

--- Returns the log for `ctx`'s buffer, or nil when the file cannot be written.
---@param ctx dbquery.Context
---@return dbquery.Log|nil
function Log.open(ctx)
  local path = files.log(ctx.buf, ctx.bufName)
  if not path then
    return nil
  end
  return setmetatable({ path = path, runs = 0 }, Log)
end

--- Writes `run`'s heading and sql, and opens the block the client writes into,
--- so the pane has something to show before the client prints anything. The
--- heading numbers the run, because a cancelled run goes on writing while its
--- replacement appends to the same file.
---@param run dbquery.Run
function Log:begin(run)
  self.runs = self.runs + 1
  local heading = { "# " .. self.runs, os.date("%H:%M:%S") }
  if run.ctx.connectionName then
    table.insert(heading, run.ctx.connectionName)
  end
  local lines = {
    table.concat(heading, " · "),
    "",
    SQL_FENCE .. "sql",
    run.ctx.sql,
    SQL_FENCE,
    "",
    OUTPUT_FENCE_OPEN,
  }
  append(self.path, table.concat(lines, "\n"))
end

--- Closes the block the client writes into and states how `run` ended, as the
--- mark in the sql buffer does. A run that wrote rows names the results file
--- inside the block. A client whose last line has no newline gets one, since a
--- closing fence is only a fence at the start of a line.
---@param run dbquery.Run
---@param startError string|nil Why the process could not start, for a run that has none.
function Log:close(run, startError)
  if startError then
    append(self.path, startError)
  end

  local lastChar = "\n"
  local file = io.open(self.path, "r")
  if file then
    local size = file:seek("end")
    lastChar = size > 0 and file:seek("set", size - 1) and file:read(1) or "\n"
    file:close()
  end

  local status = startError and "failed" or run.process.status
  local ending = startError and "failed to start" or runStatus.summary(run.process)
  local lines = {}
  if lastChar ~= "\n" then
    table.insert(lines, "")
  end
  if status == "ok" and run.path then
    table.insert(lines, "saved to " .. run.path)
  end
  vim.list_extend(lines, {
    OUTPUT_FENCE_CLOSE,
    "",
    runStatus.icon(status) .. " " .. ending,
    "",
    SEPARATOR,
    "",
    "",
  })
  append(self.path, table.concat(lines, "\n"))
end

return Log
