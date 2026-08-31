--[[
Coordinates queries from a sql buffer.

A Source ties together a Run, Pane, and Indicator for one buffer. Each buffer
can have one active query at a time.
]]

local config = require("db-query.config")
local Indicator = require("db-query.indicator")
local Pane = require("db-query.pane")
local Run = require("db-query.run")

---@class dbquery.Source
---@field buf integer
---@field pane dbquery.Pane
---@field run dbquery.Run|nil
---@field indicator dbquery.Indicator|nil
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

--- Returns the Source whose pane is showing `buf`, or nil.
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

--- Returns spinner status for `buf` (as source or output pane), or empty string.
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

--- Cancels the active query, if any.
function Source:cancel()
  if self.run then
    self.run:cancel()
  end
end

--- Cleans up when the source buffer is wiped. Cancels any running query and
--- stops the indicator. Leaves existing output windows open.
function Source:close()
  self:cancel()
  if self.indicator then
    self.indicator:stop()
  end
  self.pane:stop()
  sources[self.buf] = nil
end

---@class dbquery.ExecuteSpec
---@field url string|nil
---@field resolved string
---@field sql string
---@field mode dbquery.Mode
---@field span [integer, integer]
---@field outputPath string|nil

--- Runs `spec.sql`, replacing any active query. The previous query is cancelled
--- but may still be finishing when this one starts.
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
