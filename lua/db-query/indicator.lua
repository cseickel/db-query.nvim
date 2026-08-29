--[[
What a buffer shows while its query is running.

A bar runs down the left edge of the lines that were sent and continues onto
the virtual line under them that holds the spinner, the clock and the cancel
key. All of it is buffer local, which is why a buffer runs one query at a time:
a second one would draw over the first and take its key.

The bar and the spinner scroll with the query they belong to, so a buffer long
enough to scroll them out of sight has `status` for the winbar instead.
]]

---@class dbquery.Indicator
---@field buf integer
---@field first integer The first line that was sent, zero based.
---@field last integer The last line that was sent, zero based.
---@field key string The key bound to stop the query.
---@field width integer The display width of the last line that was sent.
---@field run dbquery.Run
---@field frame integer Which spinner frame is drawn.
---@field timer uv.uv_timer_t|nil Absent once the indicator has stopped.
local Indicator = {}
Indicator.__index = Indicator

-- Bound in visual mode too, because a query is often started from a selection
-- and the selection is still there while it runs.
local MODES = { "n", "x" }

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Half a cell, so the colour is the left edge of the column and the rest of it
-- is the background the buffer already had.
local BAR = "▌"

-- Every mark is named rather than left for nvim to name, so that redrawing the
-- spinner moves it rather than leaving one behind, and so that no two of them
-- can end up sharing a name.
local NAMESPACE = vim.api.nvim_create_namespace("db_query_indicator")
local SPINNER = 1
local RANGE = 2
local FRAME_TIME = 80

-- The spinner line is underlined, which is an attribute rather than a colour,
-- so it is a second group combined with the first rather than a second colour
-- to set.
local UNDERLINE = "DbQueryIndicatorUnderline"

local function defineHighlights()
  vim.api.nvim_set_hl(0, "DbQueryIndicator", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, UNDERLINE, { underline = true })
end

defineHighlights()
-- A colorscheme clears every group, so the links have to be laid down again
-- after one loads or the indicator loses its colours mid-session.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("db-query.indicator", { clear = true }),
  callback = defineHighlights,
})

--- The display width of the last line that was sent, which is the line the
--- spinner is drawn under and so the width it is drawn out to.
---@return integer
function Indicator:textWidth()
  local at = math.min(self.last, vim.api.nvim_buf_line_count(self.buf) - 1)
  local line = vim.api.nvim_buf_get_lines(self.buf, at, at + 1, false)[1]
  return vim.fn.strdisplaywidth(line or "")
end

--- Draws the bar beside the lines that were sent, in the sign column, which is
--- the only column of a window that no other plugin draws in without being a
--- sign itself. Column zero of the text is where indent guides go, and they
--- are stamped onto the screen rather than inserted into the line, so a bar
--- drawn there is painted over on every indented line.
---
--- The lines are clamped, because the sql is read before the connection is
--- chosen and the buffer can lose lines while that chooser is open.
function Indicator:drawBar()
  local bottom = vim.api.nvim_buf_line_count(self.buf) - 1
  vim.api.nvim_buf_set_extmark(self.buf, NAMESPACE, math.min(self.first, bottom), 0, {
    id = RANGE,
    end_row = math.min(self.last, bottom),
    sign_text = BAR,
    sign_hl_group = "DbQueryIndicator",
  })
end

--- How many columns a window puts before the text it shows, which is the sign
--- column, the number column and the fold column together. The buffer can be
--- in several windows and the spinner line is drawn once for all of them, so
--- the first is the one it lines up with.
---@param buf integer
---@return integer
local function textColumn(buf)
  local win = vim.fn.win_findbuf(buf)[1]
  local info = win and vim.fn.getwininfo(win)[1]
  return info and info.textoff or 1
end

--- Redraws the spinner where it is now, which is under the last line that was
--- sent until an edit moves it. Reloading the buffer drops the mark and can
--- leave the line it was on past the end, so the fallback is clamped rather
--- than trusted.
---
--- The line starts with the bar so the sign column carries on into it, then
--- reaches the column the query starts at and runs to the width of the line
--- above it, so that what is underlined is the query rather than the spinner.
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

--- The spinner and the clock as one string, for a winbar or a statusline.
--- Empty once the query has ended.
---@return string
function Indicator:status()
  if self.run.status ~= "running" then
    return ""
  end
  return string.format("%s %.1fs", FRAMES[self.frame], self.run:elapsed())
end

--- Turns the spinner one frame and redraws every winbar and statusline, since
--- nvim has no way to know that a spinner turning in lua changed one. The
--- window showing this query's output asks for the same spinner, so the redraw
--- cannot be narrowed to the windows showing this buffer.
---
--- A tick is queued on the main loop rather than run where the timer fires, so
--- a tick can still be waiting when the query ends. Drawing that one would put
--- the spinner back on screen for good, which is what the `self.timer` check
--- prevents.
---
--- `:bdelete` unloads a buffer without wiping it, so a query can outlive the
--- lines it was drawn on and still be one the window showing its output is
--- waiting for. Only the drawing needs those lines.
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

--- Takes the bar, the spinner and the key away. Called for itself when the
--- query ends, and by the source when a second query replaces the first.
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

---@class dbquery.IndicatorSpec
---@field buf integer The buffer the query came from.
---@field span [integer, integer] The first and last line that were sent.
---@field run dbquery.Run
---@field key string The key that stops the query.

--- Draws the bar beside the lines `spec.run` is running, the spinner under
--- them, and binds `spec.key` to stop it, until the query ends.
---@param spec dbquery.IndicatorSpec
---@return dbquery.Indicator
function Indicator.attach(spec)
  local self = setmetatable({
    buf = spec.buf,
    first = spec.span[1],
    last = spec.span[2],
    key = spec.key,
    run = spec.run,
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
  spec.run:onFinish(function()
    self:stop()
  end)
  return self
end

return Indicator
