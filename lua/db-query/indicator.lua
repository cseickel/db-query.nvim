--[[
What a buffer shows while its query is running.

The lines that were sent are highlighted, a spinner and a clock are drawn on a
virtual line under them, and the cancel key is bound. All three are buffer
local, which is why a buffer runs one query at a time: a second one would draw
over the first and take its key.

The highlight and the spinner scroll with the query they belong to, so a buffer
long enough to scroll them out of sight has `status` for the winbar instead.
]]

---@class dbquery.Indicator
---@field buf integer
---@field first integer The first line that was sent, zero based.
---@field last integer The last line that was sent, zero based.
---@field key string The key bound to stop the query.
---@field run dbquery.Run
---@field frame integer Which spinner frame is drawn.
---@field timer uv.uv_timer_t|nil Absent once the indicator has stopped.
local Indicator = {}
Indicator.__index = Indicator

-- Bound in visual mode too, because a query is often started from a selection
-- and the selection is still there while it runs.
local MODES = { "n", "x" }

local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Both marks are named rather than left for nvim to name, so that redrawing
-- the spinner moves it rather than leaving one behind, and so that the two
-- cannot end up sharing a name.
local NAMESPACE = vim.api.nvim_create_namespace("db_query_indicator")
local RANGE = 1
local SPINNER = 2
local FRAME_TIME = 80

local function defineHighlights()
  vim.api.nvim_set_hl(0, "DbQueryRunning", { link = "CursorLine", default = true })
  vim.api.nvim_set_hl(0, "DbQuerySpinner", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "DbQueryElapsed", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "DbQueryCancelHint", { link = "NonText", default = true })
end

defineHighlights()
-- A colorscheme clears every group, so the links have to be laid down again
-- after one loads or the indicator loses its colours mid-session.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("db-query.indicator", { clear = true }),
  callback = defineHighlights,
})

--- Marks the lines that were sent, as one range, so that editing inside the
--- query keeps the highlight around it.
---
--- The lines are clamped, because the sql is read before the connection is
--- chosen and the buffer can lose lines while that chooser is open.
function Indicator:highlight()
  local bottom = vim.api.nvim_buf_line_count(self.buf) - 1
  vim.api.nvim_buf_set_extmark(self.buf, NAMESPACE, math.min(self.first, bottom), 0, {
    id = RANGE,
    end_row = math.min(self.last, bottom),
    line_hl_group = "DbQueryRunning",
  })
end

--- Redraws the spinner where it is now, which is under the last line that was
--- sent until an edit moves it. Reloading the buffer drops the mark and can
--- leave the line it was on past the end, so the fallback is clamped rather
--- than trusted.
function Indicator:draw()
  local bottom = vim.api.nvim_buf_line_count(self.buf) - 1
  local placed = vim.api.nvim_buf_get_extmark_by_id(self.buf, NAMESPACE, SPINNER, {})
  local at = math.min(placed[1] or self.last, bottom)

  vim.api.nvim_buf_set_extmark(self.buf, NAMESPACE, at, 0, {
    id = SPINNER,
    virt_lines = {
      {
        { "  " .. FRAMES[self.frame] .. "  ", "DbQuerySpinner" },
        { string.format("%.1fs", self.run:elapsed()), "DbQueryElapsed" },
        { "    " .. self.key .. " to cancel", "DbQueryCancelHint" },
      },
    },
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

--- Turns the spinner one frame and redraws everything showing it, since nvim
--- has no way to know that a spinner turning in lua changed the winbar.
---
--- `:bdelete` unloads a buffer without wiping it, so a query can outlive the
--- lines it was drawn on.
function Indicator:tick()
  if not vim.api.nvim_buf_is_loaded(self.buf) then
    return
  end
  self.frame = self.frame % #FRAMES + 1
  self:draw()
  vim.api.nvim__redraw({ buf = self.buf, statusline = true, winbar = true })
end

--- Takes the highlight, the spinner and the key away. Called for itself when
--- the query ends, and by the source when a second query replaces the first.
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
    vim.api.nvim__redraw({ buf = self.buf, statusline = true, winbar = true })
  end
end

---@class dbquery.IndicatorSpec
---@field buf integer The buffer the query came from.
---@field span [integer, integer] The first and last line that were sent.
---@field run dbquery.Run
---@field key string The key that stops the query.

--- Marks the lines `spec.run` is running, draws a spinner under them, and binds
--- `spec.key` to stop it, until the query ends.
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

  vim.keymap.set(MODES, self.key, function()
    self.run:cancel()
  end, { buffer = self.buf, desc = "cancel the running query" })

  self:highlight()
  self:draw()
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
