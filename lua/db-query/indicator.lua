--[[
Visual indicator while a process runs: a query, or a connection test.

A bar marks the lines the process is about, with a spinner, what it is doing,
and a timer on a virtual line below. The cancel key is bound while it runs.
All state is buffer-local, so each buffer shows one process at a time.

`status()` provides the same spinner for a winbar or statusline, which the user
would have to configure themselves.
]]

local config = require("db-query.config")
local main = require("db-query.main")

--- Where an indicator draws, and what it says the process is doing.
---@class dbquery.Place
---@field buf integer
---@field span [integer, integer] First and last line the bar marks (0-based).
---@field label string Such as "running query".

---@class dbquery.Indicator
---@field buf integer
---@field first integer First marked line (0-based).
---@field last integer Last marked line (0-based).
---@field label string
---@field key string Cancel keybinding.
---@field width integer Display width of the last line.
---@field process dbquery.Process
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
Indicator.FRAME_TIME = FRAME_TIME

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
function Indicator.format(label, seconds)
  return string.format("%s %s %.1fs", frameAt(seconds), label:gsub("%%", "%%%%"), seconds)
end

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

--- Draws the bar in the sign column beside the marked lines.
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

--- Draws the spinner, label, timer, and cancel hint on a virtual line below
--- the marked lines.
function Indicator:drawSpinner()
  local bottom = vim.api.nvim_buf_line_count(self.buf) - 1
  local placed = vim.api.nvim_buf_get_extmark_by_id(self.buf, NAMESPACE, SPINNER, {})
  local at = math.min(placed[1] or self.last, bottom)

  local indent = textColumn(self.buf)
  local text = BAR
    .. string.rep(" ", indent - 1)
    .. string.format("%s  %s  %.1fs    %s to cancel", frameAt(self.process:elapsed()), self.label, self.process:elapsed(), self.key)
  text = text .. string.rep(" ", indent + self.width - vim.fn.strdisplaywidth(text))

  vim.api.nvim_buf_set_extmark(self.buf, NAMESPACE, at, 0, {
    id = SPINNER,
    virt_lines = { { { text, { "DbQueryIndicator", UNDERLINE } } } },
    virt_lines_leftcol = true,
  })
end

--- Returns the spinner, label, and elapsed time for a winbar or statusline, or
--- an empty string once the process has finished.
---@return string
function Indicator:status()
  if self.process.status ~= "running" then
    return ""
  end
  return Indicator.format(self.label, self.process:elapsed())
end

--- Advances the spinner and triggers a redraw. Skipped if the indicator has
--- stopped, which a timer callback scheduled before the process ended can be.
function Indicator:tick()
  if not self.timer then
    return
  end
  if vim.api.nvim_buf_is_loaded(self.buf) then
    self:drawSpinner()
  end
  vim.api.nvim__redraw({ statusline = true, winbar = true })
end

--- Removes the bar, spinner, and keybinding.
---
--- A second call finds `timer` nil and does nothing. A replaced indicator is
--- stopped when its successor is attached and stopped again when its own
--- process finishes, and that second call would otherwise delete the
--- successor's keymap and clear its extmarks.
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

--- Creates an indicator for `process` at `place`, drawing the bar and spinner
--- and binding the cancel key. Stops automatically when the process finishes.
---@param process dbquery.Process
---@param place dbquery.Place
---@return dbquery.Indicator
function Indicator.attach(process, place)
  local self = setmetatable({
    buf = place.buf,
    first = place.span[1],
    last = place.span[2],
    label = place.label,
    key = config.values.cancel,
    process = process,
    timer = vim.uv.new_timer(),
  }, Indicator)
  self.width = self:textWidth()

  vim.keymap.set(MODES, self.key, function()
    self.process:cancel()
  end, { buffer = self.buf, desc = "cancel " .. place.label })

  self:drawBar()
  self:drawSpinner()
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

return Indicator
