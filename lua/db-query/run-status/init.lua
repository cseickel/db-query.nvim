--[[
How a query's run status is shown: marked in the sql buffer while it runs and
after it ends, and colored in the log's status line. `progress.lua` marks a
query while it runs, and `result.lua` after it ends.

Each status has a color, and a finished one an icon and a summary. A query's
mark is a sign beside its first line, a bar down the gutter beside the rest,
and an elbow turning under the query to a line of text:

    sign │ select month, sum(amount)
    │    │ from trades
    ╰──────▏ 2,520 rows in 0.98s ▕─────────

The elbow line runs to where the query's last line ended when the run started,
or past it when the text is longer.

The log is a markdown file, so its status lines are colored as they are drawn,
in any window showing a buffer marked `b:db_query_log`.
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

--- Cells between the text column and the start of the elbow's text, where no
--- line of sql starts.
local INDENT = 3

--- Fewest cells between the elbow's bars, which the text is centered in, so
--- the band keeps its width as the clock ticks and as a run finishes.
local RUNNING_MESSAGE = 40
local FINISHED_MESSAGE = 20

---@param ending dbquery.Status A finished process's status.
---@return string
function M.icon(ending)
  return config.values.icons[ending]
end

--- What a query is marked with, over rows `first` to `last` (0-based).
---@class dbquery.Mark
---@field first integer
---@field last integer
---@field status dbquery.Status
---@field sign string Drawn beside the first row, cut to the two cells a sign holds.
---@field text string Drawn on the elbow under the last row.
---@field width integer Cells past the gutter the elbow line reaches at least, from `widthAt`.

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

--- Returns the text offset (sign + number + fold columns) for `buf`'s window.
---@param buf integer
---@return integer
local function textColumn(buf)
  local win = vim.fn.win_findbuf(buf)[1]
  local info = win and vim.fn.getwininfo(win)[1]
  return info and info.textoff or 1
end

--- Returns the width an elbow under `row` reaches at least past the gutter,
--- which is the width of the row's text.
---@param buf integer
---@param row integer
---@return integer
function M.widthAt(buf, row)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  return vim.fn.strdisplaywidth(line)
end

--- Returns `text` padded on both sides to center it in `cells`, with a space
--- on each side when it is as wide or wider.
---@param text string
---@param cells integer
---@return string
local function centered(text, cells)
  local spare = math.max(2, cells - vim.fn.strdisplaywidth(text))
  local left = math.floor(spare / 2)
  return string.rep(" ", left) .. text .. string.rep(" ", spare - left)
end

--- Draws the bar beside `mark`'s rows after the first, and the elbow under its
--- last row turning to its text.
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

  local gutter = textColumn(buf)
  local elbow = "╰" .. string.rep("─", gutter + INDENT - 1)
  local message = mark.status == "running" and RUNNING_MESSAGE or FINISHED_MESSAGE
  local text = { TEXT[mark.status], ITALIC }
  local chunks = {
    { elbow, color },
    { "▏", text },
    { centered(mark.text, message), text },
    -- Drawn along the cell's right edge, where the band ends.
    { "▕", BAND[mark.status] },
  }
  local drawn = 0
  for _, chunk in ipairs(chunks) do
    drawn = drawn + vim.fn.strdisplaywidth(chunk[1])
  end
  local trailing = gutter + mark.width - drawn
  if trailing > 0 then
    table.insert(chunks, { string.rep("─", trailing), color })
  end

  vim.api.nvim_buf_set_extmark(buf, namespace, mark.last, 0, {
    virt_lines = { chunks },
    virt_lines_leftcol = true,
  })
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

--- Defines the band and its text for `status` from the status color and the
--- background, or as the plain status color when either is unknown.
---@param status dbquery.Status
local function defineBand(status)
  local color = vim.api.nvim_get_hl(0, { name = HIGHLIGHT[status], link = false }).fg
  local background = vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
  if color and background then
    local tint = mix(color, background, TINT)
    vim.api.nvim_set_hl(0, BAND[status], { fg = color, bg = tint, default = true })
    vim.api.nvim_set_hl(0, TEXT[status], { fg = mix(color, background, DIM), bg = tint, default = true })
  else
    vim.api.nvim_set_hl(0, BAND[status], { link = HIGHLIGHT[status], default = true })
    vim.api.nvim_set_hl(0, TEXT[status], { link = HIGHLIGHT[status], default = true })
  end
end

--- How a finished run reads when the client gives no count.
---@type table<dbquery.Status, string>
local ENDED = { ok = "finished in", failed = "failed after", cancelled = "cancelled after" }

--- Returns `count` with a comma between each group of three digits.
---@param count integer
---@return string
local function grouped(count)
  local digits = tostring(count)
  return (digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

--- Returns how the finished `process` ended, such as `2,520 rows in 0.98s`,
--- with the rows it wrote when the client says.
---@param process dbquery.Process
---@return string
function M.summary(process)
  local seconds = string.format("%.2fs", process:elapsed())
  if process.status == "ok" and process.rows then
    return string.format("%s %s in %s", grouped(process.rows), process.rows == 1 and "row" or "rows", seconds)
  end
  return ENDED[process.status] .. " " .. seconds
end

local function defineHighlights()
  vim.api.nvim_set_hl(0, HIGHLIGHT.running, { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, HIGHLIGHT.ok, { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, HIGHLIGHT.failed, { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, HIGHLIGHT.cancelled, { link = "DiagnosticHint", default = true })
  vim.api.nvim_set_hl(0, ITALIC, { italic = true })
  for status in pairs(BAND) do
    defineBand(status)
  end
end

defineHighlights()
-- Colorschemes clear all groups, so re-apply after a scheme loads.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("db-query.run-status", { clear = true }),
  callback = defineHighlights,
})

local NAMESPACE = vim.api.nvim_create_namespace("db_query_log_status")

vim.api.nvim_set_decoration_provider(NAMESPACE, {
  on_win = function(_, _, buf)
    return vim.b[buf].db_query_log == true
  end,
  on_line = function(_, _, buf, row)
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    for ending, icon in pairs(config.values.icons) do
      if icon ~= "" and line:sub(1, #icon) == icon then
        vim.api.nvim_buf_set_extmark(buf, NAMESPACE, row, 0, {
          end_col = #line,
          hl_group = HIGHLIGHT[ending],
          ephemeral = true,
        })
        return
      end
    end
  end,
})

return M
