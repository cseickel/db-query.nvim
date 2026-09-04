--[[
Visual indicator while a query runs.

A bar marks the lines being executed, with a spinner and timer on a virtual
line below. The cancel key is bound while the query runs. All state is buffer-
local, so each buffer can run one query at a time.

`status()` provides the same spinner for a winbar or statusline, which the user
would have to configure themselves.
]]

local config = require("db-query.config")

---@class dbquery.Indicator
---@field buf integer
---@field first integer First executed line (0-based).
---@field last integer Last executed line (0-based).
---@field key string Cancel keybinding.
---@field width integer Display width of the last line.
---@field run dbquery.Run
---@field frame integer Current spinner frame.
---@field timer uv.uv_timer_t|nil Nil after stop().
local Indicator = {}
Indicator.__index = Indicator

local MODES = { "n", "x" }

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local BAR = "▌"

local NAMESPACE = vim.api.nvim_create_namespace("db_query_indicator")
local SPINNER = 1
local RANGE = 2
local FRAME_TIME = 80

local UNDERLINE = "DbQueryIndicatorUnderline"

local function defineHighlights()
  vim.api.nvim_set_hl(0, "DbQueryIndicator", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, UNDERLINE, { underline = true })
end

defineHighlights()
-- Colorschemes clear all groups, so re-apply after a scheme loads.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("db-query.indicator", { clear = true }),
  callback = defineHighlights,
})

---@return integer
function Indicator:textWidth()
  local at = math.min(self.last, vim.api.nvim_buf_line_count(self.buf) - 1)
  local line = vim.api.nvim_buf_get_lines(self.buf, at, at + 1, false)[1]
  return vim.fn.strdisplaywidth(line or "")
end

--- Draws the bar in the sign column beside the executed lines.
function Indicator:drawBar()
  local bottom = vim.api.nvim_buf_line_count(self.buf) - 1
  vim.api.nvim_buf_set_extmark(self.buf, NAMESPACE, math.min(self.first, bottom), 0, {
    id = RANGE,
    end_row = math.min(self.last, bottom),
    sign_text = BAR,
    sign_hl_group = "DbQueryIndicator",
  })
end

--- Returns the text offset (sign + number + fold columns) for `buf`'s window.
---@param buf integer
---@return integer
local function textColumn(buf)
  local win = vim.fn.win_findbuf(buf)[1]
  local info = win and vim.fn.getwininfo(win)[1]
  return info and info.textoff or 1
end

--- Draws the spinner, timer, and cancel hint on a virtual line below the query.
function Indicator:drawSpinner()
  local bottom = vim.api.nvim_buf_line_count(self.buf) - 1
  local placed = vim.api.nvim_buf_get_extmark_by_id(self.buf, NAMESPACE, SPINNER, {})
  local at = math.min(placed[1] or self.last, bottom)

  local indent = textColumn(self.buf)
  local text = BAR
    .. string.rep(" ", indent - 1)
    .. string.format("%s  %.1fs    %s to cancel", FRAMES[self.frame], self.run:elapsed(), self.key)
  text = text .. string.rep(" ", indent + self.width - vim.fn.strdisplaywidth(text))

  vim.api.nvim_buf_set_extmark(self.buf, NAMESPACE, at, 0, {
    id = SPINNER,
    virt_lines = { { { text, { "DbQueryIndicator", UNDERLINE } } } },
    virt_lines_leftcol = true,
  })
end

--- Returns spinner and elapsed time for winbar/statusline, or empty string.
---@return string
function Indicator:status()
  if self.run.status ~= "running" then
    return ""
  end
  return string.format("%s %.1fs", FRAMES[self.frame], self.run:elapsed())
end

--- Advances the spinner and triggers a redraw. Skipped if the indicator has
--- stopped (handles late timer callbacks after the query ends).
function Indicator:tick()
  if not self.timer then
    return
  end
  self.frame = self.frame % #FRAMES + 1
  if vim.api.nvim_buf_is_loaded(self.buf) then
    self:drawSpinner()
  end
  vim.api.nvim__redraw({ statusline = true, winbar = true })
end

--- Removes the bar, spinner, and keybinding.
---
--- The nil timer makes this idempotent, which matters because a replaced
--- indicator is stopped when its successor is attached and stopped again when
--- its own run finally finishes. Without the guard the second call would delete
--- the successor's keymap and clear its extmarks.
function Indicator:stop()
  if not self.timer then
    return
  end
  self.timer:stop()
  self.timer:close()
  self.timer = nil

  if vim.api.nvim_buf_is_loaded(self.buf) then
    pcall(vim.keymap.del, MODES, self.key, { buffer = self.buf })
    vim.api.nvim_buf_clear_namespace(self.buf, NAMESPACE, 0, -1)
  end
  vim.api.nvim__redraw({ statusline = true, winbar = true })
end

--- Creates an indicator for `run`, drawing the bar and spinner and binding the
--- cancel key. Stops automatically when the run finishes.
---@param run dbquery.Run
---@return dbquery.Indicator
function Indicator.attach(run)
  local self = setmetatable({
    buf = run.ctx.buf,
    first = run.ctx.span[1],
    last = run.ctx.span[2],
    key = config.values.cancel,
    run = run,
    frame = 1,
    timer = vim.uv.new_timer(),
  }, Indicator)
  self.width = self:textWidth()

  vim.keymap.set(MODES, self.key, function()
    self.run:cancel()
  end, { buffer = self.buf, desc = "cancel the running query" })

  self:drawBar()
  self:drawSpinner()
  self.timer:start(
    FRAME_TIME,
    FRAME_TIME,
    vim.schedule_wrap(function()
      self:tick()
    end)
  )
  run:onFinish(function()
    self:stop()
  end)
  return self
end

return Indicator
