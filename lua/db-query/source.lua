--[[
A buffer that queries are run from.

This is where the rule that a buffer runs one query at a time is kept, and the
only place that knows a run, a pane, and an indicator all belong to the same
piece of work. Everything below it is independent: a run does not know it is
being watched, and a pane does not know how to start anything.

The source is the buffer rather than the window because a window shows a
different buffer later, and because the indicator and its key are buffer local
and cannot be told apart per window. The connection is not held here either,
since `b:db` is where dadbod and its completion source both read it.
]]

local config = require("db-query.config")
local Indicator = require("db-query.indicator")
local Pane = require("db-query.pane")
local Run = require("db-query.run")

---@class dbquery.Source
---@field buf integer
---@field pane dbquery.Pane
---@field run dbquery.Run|nil The query in flight, while there is one.
---@field indicator dbquery.Indicator|nil
local Source = {}
Source.__index = Source

---@type table<integer, dbquery.Source>
local sources = {}

--- The source `buf` is, making it if this is its first query. It lasts as long
--- as the buffer does.
---@param buf integer
---@return dbquery.Source
function Source.of(buf)
  local existing = sources[buf]
  if existing then
    return existing
  end

  local self = setmetatable({ buf = buf, pane = Pane.new(buf) }, Source)
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

--- The source whose pane is showing `buf`, which is how output answers for the
--- query that is filling it in. Output left over from an earlier run is in no
--- pane and answers for nothing.
---@param buf integer
---@return dbquery.Source|nil
local function showing(buf)
  for _, source in pairs(sources) do
    if source.pane:shows(buf) then
      return source
    end
  end
  return nil
end

--- What `buf` shows in a winbar or a statusline while its query runs, and an
--- empty string the rest of the time. A buffer that has never run one has no
--- source, and is not given one for asking.
---
--- A winbar over the output says the same as the one over the sql it came from,
--- which is what the greyed window it is drawn over is waiting for.
---@param buf integer
---@return string
function Source.status(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return ""
  end
  local self = sources[buf] or showing(buf)
  if not (self and self.indicator) then
    return ""
  end
  return self.indicator:status()
end

--- Asks the query in flight to stop, if there is one.
function Source:cancel()
  if self.run then
    self.run:cancel()
  end
end

--- Gives up on this buffer: the query it is running has nobody left to read
--- it, and the indicator is drawn in a buffer that is going.
---
--- An output window that is already open is left where it is, since it shows a
--- file that is worth reading after the query it came from has been closed.
--- The pane is told to stop so that a query still finishing does not open a
--- new one, which would split off whatever the user is looking at instead.
function Source:close()
  self:cancel()
  if self.indicator then
    self.indicator:stop()
  end
  self.pane:stop()
  sources[self.buf] = nil
end

---@class dbquery.ExecuteSpec
---@field url string|nil The connection as it was written, which the output buffer carries.
---@field resolved string The connection the client is given, which may hold a password.
---@field sql string
---@field mode dbquery.Mode
---@field span [integer, integer] The first and last line the sql was taken from.
---@field outputPath string|nil The path and base name the user asked the output to be written to.

--- Runs `spec.sql`, taking the place of whatever this buffer was running.
---
--- Starting a second query asks the first to stop rather than leaving a client
--- running that nothing holds a handle to. The first is only asked, so it may
--- still be finishing when this one starts, and it has already lost the
--- indicator and the pane by then.
---@param spec dbquery.ExecuteSpec
function Source:execute(spec)
  self:cancel()
  if self.indicator then
    self.indicator:stop()
  end

  local run = Run.start({
    url = spec.url,
    resolved = spec.resolved,
    sql = spec.sql,
    mode = spec.mode,
    srcName = vim.api.nvim_buf_get_name(self.buf),
    outputPath = spec.outputPath,
  })
  if not run then
    return
  end

  self.run = run
  run:onFinish(function()
    if self.run == run then
      self.run = nil
    end
  end)

  self.indicator = Indicator.attach({
    buf = self.buf,
    span = spec.span,
    run = run,
    key = config.values.cancel,
  })
  self.pane:display(run)
end

return Source
