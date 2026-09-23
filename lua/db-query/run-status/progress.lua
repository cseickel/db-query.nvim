--[[
The progress of a running process: a query, or a connection test.

The lines the process is about get the run-status mark in the running color: a
spinner beside the first line, and an elbow under the last turning to what it
is doing, a timer, and the cancel key. The cancel key is bound while it runs.
All state is buffer-local, so each buffer shows one process at a time.

`statusline()` provides the spinner, what is running, and the timer for a winbar
or statusline, which the user would have to configure themselves.
]]

local config = require("db-query.config")
local main = require("db-query.main")
local runStatus = require("db-query.run-status")

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
---@field timer uv.uv_timer_t|nil Nil after stop().
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
  local placed = vim.api.nvim_buf_get_extmark_by_id(self.buf, SPANS, SPAN, { details = true })
  local first, details = placed[1], placed[3]
  if not (first and details) then
    return
  end
  local seconds = self.process:elapsed()
  ---@type dbquery.Mark
  local mark = {
    first = first,
    last = math.max(first, details.end_row or first),
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

--- Advances the spinner and triggers a redraw. Skipped if the progress has
--- stopped, which a timer callback scheduled before the process ended can be.
function Progress:tick()
  if not self.timer then
    return
  end
  if vim.api.nvim_buf_is_loaded(self.buf) then
    self:draw()
  end
  vim.api.nvim__redraw({ statusline = true, winbar = true })
end

--- Removes the mark and the keybinding.
---
--- A second call finds `timer` nil and does nothing. A replaced progress is
--- stopped when its successor is attached and stopped again when its own
--- process finishes, and that second call would otherwise delete the
--- successor's keymap and clear its extmarks.
function Progress:stop()
  if not self.timer then
    return
  end
  self.timer:stop()
  self.timer:close()
  self.timer = nil

  if vim.api.nvim_buf_is_loaded(self.buf) then
    pcall(vim.keymap.del, MODES, self.key, { buffer = self.buf })
    vim.api.nvim_buf_clear_namespace(self.buf, SPANS, 0, -1)
    vim.api.nvim_buf_clear_namespace(self.buf, DRAWN, 0, -1)
  end
  vim.api.nvim__redraw({ statusline = true, winbar = true })
end

--- Creates the progress of `process` at `place`, drawing its mark and binding
--- the cancel key. Stops automatically when the process finishes.
---@param process dbquery.Process
---@param place dbquery.Place
---@return dbquery.Progress
function Progress.attach(process, place)
  local self = setmetatable({
    buf = place.buf,
    label = place.label,
    key = config.values.cancel,
    process = process,
    timer = vim.uv.new_timer(),
  }, Progress)

  local bottom = vim.api.nvim_buf_line_count(self.buf) - 1
  local first, last = math.min(place.span[1], bottom), math.min(place.span[2], bottom)
  local lastLine = vim.api.nvim_buf_get_lines(self.buf, last, last + 1, false)[1]
  vim.api.nvim_buf_set_extmark(self.buf, SPANS, first, 0, {
    id = SPAN,
    end_row = last,
    end_col = #lastLine,
  })
  self.width = runStatus.widthAt(self.buf, last)

  vim.keymap.set(MODES, self.key, function()
    self.process:cancel()
  end, { buffer = self.buf, desc = "cancel " .. place.label })

  self:draw()
  self.timer:start(
    FRAME_TIME,
    FRAME_TIME,
    main.frame(function()
      self:tick()
    end)
  )
  process:onFinish(function()
    self:stop()
  end)
  return self
end

return Progress
