--[[
Coordinates what runs from a sql buffer.

A Source ties together a Run, Pane, and Progress for one buffer. Each buffer
runs one process at a time, a query or a connection test, and starting either
cancels the one before it.
]]

local catalog = require("db-query.catalog")
local Log = require("db-query.log")
local output = require("db-query.output")
local Pane = require("db-query.pane")
local Progress = require("db-query.run-status.progress")
local result = require("db-query.run-status.result")
local Run = require("db-query.run")
local sql = require("db-query.sql")

---@alias dbquery.OutputView "log"|"result"|"toggle"

---@class dbquery.Source
---@field buf integer
---@field pane dbquery.Pane
---@field log dbquery.Log|nil The log every query of this buffer appends to, opened by the first one.
---@field run dbquery.Run|nil The last query, whose files the pane shows.
---@field process dbquery.Process|nil The last process started, a query's or a connection test's.
---@field progress dbquery.Progress|nil
---@field files string[] Result files this buffer's queries have written.
local Source = {}
Source.__index = Source

---@type table<integer, dbquery.Source>
local sources = {}

--- Returns the Source for `buf`, creating one if needed.
---@param buf integer
---@return dbquery.Source
function Source.of(buf)
  local existing = sources[buf]
  if existing then
    return existing
  end

  local self = setmetatable({ buf = buf, pane = Pane.new(), files = {} }, Source)
  sources[buf] = self
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      self:close()
    end,
  })
  return self
end

--- Returns the Source for `buf`, a sql buffer or a file its queries wrote, or
--- nil for any other buffer.
---@param buf integer
---@return dbquery.Source|nil
function Source.owning(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  local owner = Pane.owner(buf)
  return sources[buf] or (owner and sources[owner])
end

--- Returns the progress's statusline text for `buf`, as the sql buffer or the
--- output its pane shows, or an empty string when nothing is running.
---@param buf integer
---@return string
function Source.statusline(buf)
  local self = Source.owning(buf)
  if not (self and self.progress) then
    return ""
  end
  return self.progress:statusline()
end

--- Cancels the running process, if any.
function Source:cancel()
  if self.process then
    self.process:cancel()
  end
end

--- Cancels the process running before `process` and shows `process` at `place`.
---@param self dbquery.Source
---@param process dbquery.Process
---@param place dbquery.Place
local function replace(self, process, place)
  self:cancel()
  if self.progress then
    self.progress:stop()
  end
  self.process = process
  self.progress = Progress.attach(process, place)
end

--- Puts the log or the last query's result in the pane, reopening the window
--- if it was closed. "toggle" asks for whichever is not on screen.
---@param view dbquery.OutputView
function Source:output(view)
  if not self.run then
    return vim.notify("db-query: nothing has run in this buffer yet", vim.log.levels.WARN)
  end

  if view == "toggle" then
    view = self.pane:showing() == self.run.log.path and "result" or "log"
  end
  if view == "log" then
    return self.pane:show(self.run, self.run.log.path, { tail = true })
  end

  if not (self.run.process.status == "ok" and self.run.path) then
    return vim.notify("db-query: the last query returned no rows", vim.log.levels.WARN)
  end
  self.pane:show(self.run, self.run.path)
end

--- Cleans up when the source buffer is wiped. Cancels any running process,
--- stops the progress, and deletes the files this buffer's queries wrote.
--- Leaves existing output windows open.
---
--- Deleting here rather than when an output window closes is what lets you
--- move between the log and the result as often as you like.
function Source:close()
  self:cancel()
  if self.progress then
    self.progress:stop()
  end
  self.pane:stop()

  if self.log then
    os.remove(self.log.path)
  end
  for _, path in ipairs(self.files) do
    if output.owns(path) then
      os.remove(path)
    end
  end
  sources[self.buf] = nil
end

--- Runs `ctx.sql`, replacing any running process. The one it replaces is
--- cancelled but may still be finishing when this one starts.
---
--- The replacement has to exist before the previous process is cancelled. A log
--- that cannot be written, an unknown url scheme, an output path it cannot
--- write, and an overwrite the user declined are all reasons no query starts,
--- and none of them is a reason to stop what is already running.
---@param ctx dbquery.Context
function Source:execute(ctx)
  local log = self.log or Log.open(ctx)
  if not log then
    return
  end
  self.log = log

  local run = Run.start(ctx, log)
  if not run then
    return
  end

  -- Kept after it finishes, so :DBOutput can still find both files.
  self.run = run
  if run.path then
    table.insert(self.files, run.path)
  end

  local span = sql.codeSpan(ctx.dialect, self.buf, ctx.span)
  replace(self, run.process, { buf = self.buf, span = span, label = "running query" })
  result.track(self.buf, span, run.process)
  self.pane:display(run)

  -- A script that failed or was cancelled may still have run its definitions.
  if sql.defines(ctx.dialect, ctx.sql) then
    run.process:onFinish(function()
      catalog.refresh(ctx.resolved)
    end)
  end
end

--- Shows a connection test of `name`, replacing any running process, which is
--- cancelled. The progress marks `span`.
---@param process dbquery.Process
---@param span [integer, integer]
---@param name string
function Source:test(process, span, name)
  replace(self, process, { buf = self.buf, span = span, label = "testing connection " .. name })
end

return Source
