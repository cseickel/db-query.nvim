--[[
Shows a running query or connection test in its sql buffer, and binds the key
that cancels it.
]]

local config = require("db-query.config")
local mainloop = require("db-query.mainloop")
local runStatus = require("db-query.query.status")

--- Where a progress mark draws, and what it says the process is doing.
---@class dbquery.Place
---@field buf integer
---@field span [integer, integer] First and last line the mark covers (0-based).
---@field label string Such as "running query".

---@class dbquery.Progress
---@field buf integer
---@field label string
---@field key string Cancel keybinding.
---@field process dbquery.Process
---@field width integer The elbow's width, measured when the progress is attached.
---@field stopTimer fun()|nil Nil after stop().
---@field bound table<integer, true> Buffers the cancel key is bound in.
local Progress = {}
Progress.__index = Progress

local MODES = { "n", "x" }

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- The extmark following the marked lines through edits.
local SPANS = vim.api.nvim_create_namespace("db_query_progress_span")
local SPAN = 1
local DRAWN = vim.api.nvim_create_namespace("db_query_progress")
local FRAME_TIME = 80
Progress.FRAME_TIME = FRAME_TIME

---@param seconds number
---@return string
local function frameAt(seconds)
  return FRAMES[math.floor(seconds * 1000 / FRAME_TIME) % #FRAMES + 1]
end

--- Returns the spinner, `label`, and `seconds` for a winbar or statusline, with
--- any `%` in the label doubled, since the statusline reads `%` as a format item.
---@param label string
---@param seconds number
---@return string
function Progress.format(label, seconds)
  return string.format("%s %s %.1fs", frameAt(seconds), label:gsub("%%", "%%%%"), seconds)
end

--- Draws the mark over the lines where edits have moved them.
function Progress:draw()
  local first, last = runStatus.spanRows(self.buf, SPANS, SPAN)
  if not (first and last) then
    return
  end
  local seconds = self.process:elapsed()
  ---@type dbquery.Mark
  local mark = {
    first = first,
    last = last,
    status = "running",
    sign = frameAt(seconds),
    text = string.format("%s %.1fs   %s to cancel", self.label, seconds, self.key),
    width = self.width,
  }
  vim.api.nvim_buf_clear_namespace(self.buf, DRAWN, 0, -1)
  runStatus.drawSign(self.buf, DRAWN, mark)
  runStatus.drawElbow(self.buf, DRAWN, mark)
end

--- Returns the spinner, label, and elapsed time for a winbar or statusline, or
--- an empty string once the process has finished.
---@return string
function Progress:statusline()
  if self.process.status ~= "running" then
    return ""
  end
  return Progress.format(self.label, self.process:elapsed())
end

--- Binds the cancel key in `buf` until the progress stops. Does nothing once it
--- has stopped.
---@param buf integer
function Progress:bind(buf)
  if not self.stopTimer or self.bound[buf] then
    return
  end
  self.bound[buf] = true
  vim.keymap.set(MODES, self.key, function()
    self.process:cancel()
  end, { buffer = buf, desc = "cancel " .. self.label })
end

--- Removes the mark and the keybindings. A second call does nothing. Without
--- that check, a replaced progress stopped again when its own process finished
--- would delete its successor's keymaps and marks.
function Progress:stop()
  if not self.stopTimer then
    return
  end
  self.stopTimer()
  self.stopTimer = nil

  for buf in pairs(self.bound) do
    if vim.api.nvim_buf_is_loaded(buf) then
      pcall(vim.keymap.del, MODES, self.key, { buffer = buf })
    end
  end
  if vim.api.nvim_buf_is_loaded(self.buf) then
    vim.api.nvim_buf_clear_namespace(self.buf, SPANS, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.buf, DRAWN, 0, -1)
  end
  vim.api.nvim__redraw({ statusline = true, winbar = true })
end

--- Creates the progress of `process` at `place`, drawing its mark and binding
--- the cancel key in `place.buf`. Stops when the process finishes.
---@param process dbquery.Process
---@param place dbquery.Place
---@return dbquery.Progress
function Progress.attach(process, place)
  local self = setmetatable({
    buf = place.buf,
    label = place.label,
    key = config.values.cancel,
    process = process,
    bound = {},
  }, Progress)

  local _, width = runStatus.followSpan(self.buf, SPANS, place.span, SPAN)
  self.width = width

  self:draw()
  self.stopTimer = mainloop.every(FRAME_TIME, function()
    if vim.api.nvim_buf_is_loaded(self.buf) then
      self:draw()
    end
    vim.api.nvim__redraw({ statusline = true, winbar = true })
  end)
  self:bind(self.buf)
  process:onFinish(function()
    self:stop()
  end)
  return self
end

return Progress
