--[[
Draws a query's run status beside the query in the sql buffer and on its
status line in the log.
]]

local config = require("db-query.config")

local M = {}

---@type table<dbquery.Status, string>
local HIGHLIGHT = {
  running = "DbQueryProgress",
  ok = "DbQueryResultOk",
  failed = "DbQueryResultError",
  cancelled = "DbQueryResultCancelled",
}

--- The band the text under a query sits on, with its bars in the status color.
---@type table<dbquery.Status, string>
local BAND = {
  running = "DbQueryProgressBand",
  ok = "DbQueryResultOkBand",
  failed = "DbQueryResultErrorBand",
  cancelled = "DbQueryResultCancelledBand",
}

--- The text on the band, dimmer than its bars.
---@type table<dbquery.Status, string>
local TEXT = {
  running = "DbQueryProgressText",
  ok = "DbQueryResultOkText",
  failed = "DbQueryResultErrorText",
  cancelled = "DbQueryResultCancelledText",
}

--- How much of the status color each mixes into the background.
local TINT = 0.1
local DIM = 0.8

local ITALIC = "DbQueryResultItalic"

--- Cells the elbow runs into the text column before its text starts.
local INDENT = 3

--- Fewest cells between the elbow's bars, which the text is centered in, so
--- the band keeps its width as the clock ticks and as a run finishes.
local RUNNING_MESSAGE = 40
local FINISHED_MESSAGE = 20

--- How a finished run reads when the client gives no count.
---@type table<dbquery.Status, string>
local ENDED = { ok = "Finished in", failed = "Failed after", cancelled = "Cancelled after" }

---@param status dbquery.Status A finished process's status.
---@return string
function M.icon(status)
  return config.values.icons[status]
end

--- What a query is marked with, over rows `first` to `last` (0-based).
---@class dbquery.Mark
---@field first integer
---@field last integer
---@field status dbquery.Status
---@field sign string Drawn beside the first row, cut to the two cells a sign holds.
---@field text string Drawn on the elbow under the last row.
---@field width integer Cells past the gutter the elbow line reaches at least, from `followSpan`.

--- Places an extmark over rows `span` of `buf`, clamped to the buffer, that
--- follows those rows through edits. Returns its id and the display width of
--- the last row's text.
---@param buf integer
---@param namespace integer
---@param span [integer, integer] First and last row (0-based).
---@param id integer|nil The id to place it under, replacing the extmark that has it.
---@return integer extmark
---@return integer width
function M.followSpan(buf, namespace, span, id)
  local bottom = vim.api.nvim_buf_line_count(buf) - 1
  local first, last = math.min(span[1], bottom), math.min(span[2], bottom)
  local lastLine = vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or ""
  local extmark = vim.api.nvim_buf_set_extmark(buf, namespace, first, 0, {
    id = id,
    end_row = last,
    end_col = #lastLine,
    invalidate = true,
  })
  return extmark, vim.fn.strdisplaywidth(lastLine)
end

--- Returns the first and last row of the extmark `followSpan` placed, or nil
--- once it is gone or its text was deleted.
---@param buf integer
---@param namespace integer
---@param extmark integer
---@return integer|nil first
---@return integer|nil last
function M.spanRows(buf, namespace, extmark)
  local placed = vim.api.nvim_buf_get_extmark_by_id(buf, namespace, extmark, { details = true })
  local first, details = placed[1], placed[3]
  if not (first and details) or details.invalid then
    return nil, nil
  end
  return first, math.max(first, details.end_row or first)
end

--- Draws `mark`'s sign beside its first row.
---@param buf integer
---@param namespace integer
---@param mark dbquery.Mark
function M.drawSign(buf, namespace, mark)
  vim.api.nvim_buf_set_extmark(buf, namespace, mark.first, 0, {
    sign_text = vim.fn.strcharpart(mark.sign, 0, 2),
    sign_hl_group = HIGHLIGHT[mark.status],
  })
end

--- Draws the bar beside `mark`'s rows after the first, and the elbow under its
--- last row that turns to its text. With the sign from `drawSign`, a finished
--- query looks like this.
---
---     ✓ select month, sum(amount)
---     │ from trades
---     ╰────▏ 2,520 rows in 0.98s ▕
---
--- The elbow line continues with `─` until it reaches `mark.width`.
---@param buf integer
---@param namespace integer
---@param mark dbquery.Mark
function M.drawElbow(buf, namespace, mark)
  local color = HIGHLIGHT[mark.status]
  if mark.last > mark.first then
    vim.api.nvim_buf_set_extmark(buf, namespace, mark.first + 1, 0, {
      end_row = mark.last,
      sign_text = "│",
      sign_hl_group = color,
    })
  end

  local win = vim.fn.win_findbuf(buf)[1]
  local info = win and vim.fn.getwininfo(win)[1]
  local gutter = info and info.textoff or 1
  local elbow = "╰" .. string.rep("─", gutter + INDENT - 1)

  local cells = mark.status == "running" and RUNNING_MESSAGE or FINISHED_MESSAGE
  local spare = math.max(2, cells - vim.fn.strdisplaywidth(mark.text))
  local left = math.floor(spare / 2)
  local centeredText = string.rep(" ", left) .. mark.text .. string.rep(" ", spare - left)

  local textHighlight = { TEXT[mark.status], ITALIC }
  local chunks = {
    { elbow, color },
    { "▏", textHighlight },
    { centeredText, textHighlight },
    -- Drawn along the cell's right edge, where the band ends.
    { "▕", BAND[mark.status] },
  }
  local drawnWidth = 0
  for _, chunk in ipairs(chunks) do
    drawnWidth = drawnWidth + vim.fn.strdisplaywidth(chunk[1])
  end
  local trailing = gutter + mark.width - drawnWidth
  if trailing > 0 then
    table.insert(chunks, { string.rep("─", trailing), color })
  end

  vim.api.nvim_buf_set_extmark(buf, namespace, mark.last, 0, {
    virt_lines = { chunks },
    virt_lines_leftcol = true,
  })
end

--- Returns how the finished `process` ended, such as `2,520 rows in 0.98s`
--- when the client reports a row count, or `Failed after 0.98s`.
---@param process dbquery.Process
---@return string
function M.summary(process)
  local seconds = string.format("%.2fs", process:elapsed())
  if process.status == "ok" and process.rows then
    local digits = tostring(process.rows):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return string.format("%s %s in %s", digits, process.rows == 1 and "row" or "rows", seconds)
  end
  return ENDED[process.status] .. " " .. seconds
end

--- Returns `color` mixed into `background`, `amount` of the way from the
--- background to the color.
---@param color integer
---@param background integer
---@param amount number
---@return integer
local function mix(color, background, amount)
  local mixed = 0
  for shift = 16, 0, -8 do
    local over = math.floor(color / 2 ^ shift) % 256
    local under = math.floor(background / 2 ^ shift) % 256
    mixed = mixed + math.floor(under + (over - under) * amount + 0.5) * 2 ^ shift
  end
  return mixed
end

--- Defines every group, deriving each band and its text from the status color
--- and the background, or linking them to the status color when either is
--- unknown.
local function defineHighlights()
  vim.api.nvim_set_hl(0, HIGHLIGHT.running, { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, HIGHLIGHT.ok, { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, HIGHLIGHT.failed, { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, HIGHLIGHT.cancelled, { link = "DiagnosticHint", default = true })
  vim.api.nvim_set_hl(0, ITALIC, { italic = true })
  local background = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
  for status in pairs(BAND) do
    local color = vim.api.nvim_get_hl(0, { name = HIGHLIGHT[status], link = false }).fg
    if color and background then
      local tint = mix(color, background, TINT)
      vim.api.nvim_set_hl(0, BAND[status], { fg = color, bg = tint, default = true })
      vim.api.nvim_set_hl(0, TEXT[status], { fg = mix(color, background, DIM), bg = tint, default = true })
    else
      vim.api.nvim_set_hl(0, BAND[status], { link = HIGHLIGHT[status], default = true })
      vim.api.nvim_set_hl(0, TEXT[status], { link = HIGHLIGHT[status], default = true })
    end
  end
end

defineHighlights()
-- Colorschemes clear all groups, so re-apply after a scheme loads.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("db-query.query.status", { clear = true }),
  callback = defineHighlights,
})

-- The log is a markdown file, so its status lines are colored as they are
-- drawn, in any window showing a buffer marked `b:db_query_log`.
local NAMESPACE = vim.api.nvim_create_namespace("db_query_log_status")

vim.api.nvim_set_decoration_provider(NAMESPACE, {
  on_win = function(_, _, buf)
    return vim.b[buf].db_query_log == true
  end,
  on_line = function(_, _, buf, row)
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    for status, icon in pairs(config.values.icons) do
      if icon ~= "" and line:sub(1, #icon) == icon then
        vim.api.nvim_buf_set_extmark(buf, NAMESPACE, row, 0, {
          end_col = #line,
          hl_group = HIGHLIGHT[status],
          ephemeral = true,
        })
        return
      end
    end
  end,
})

return M
