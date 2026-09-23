--[[
How a finished query is marked: an icon, a color, and a summary for each way it
can end, shared by the sql buffer's marks and the log's status line.

The log is a markdown file, so its status lines are colored as they are drawn,
in any window showing a buffer marked `b:db_query_log`.
]]

local config = require("db-query.config")

local M = {}

---@type table<dbquery.Status, string>
local HIGHLIGHT = {
  ok = "DbQueryResultOk",
  failed = "DbQueryResultError",
  cancelled = "DbQueryResultCancelled",
}

--- The band the result under a query sits on, with its bars in the status color.
---@type table<dbquery.Status, string>
local BAND = {
  ok = "DbQueryResultOkBand",
  failed = "DbQueryResultErrorBand",
  cancelled = "DbQueryResultCancelledBand",
}

--- The result's text on the band, dimmer than its bars.
---@type table<dbquery.Status, string>
local TEXT = {
  ok = "DbQueryResultOkText",
  failed = "DbQueryResultErrorText",
  cancelled = "DbQueryResultCancelledText",
}

--- How much of the status color each mixes into the background.
local TINT = 0.1
local DIM = 0.75

M.ITALIC = "DbQueryResultItalic"

---@param ending dbquery.Status A finished process's status.
---@return string
function M.icon(ending)
  return config.values.icons[ending]
end

---@param ending dbquery.Status A finished process's status.
---@return string
function M.highlight(ending)
  return HIGHLIGHT[ending]
end

---@param ending dbquery.Status A finished process's status.
---@return string
function M.band(ending)
  return BAND[ending]
end

---@param ending dbquery.Status A finished process's status.
---@return string
function M.text(ending)
  return TEXT[ending]
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
local ENDED = { ok = "finished", failed = "failed", cancelled = "cancelled" }

--- Returns how the finished `process` ended, such as `2520 rows in 0.98s`,
--- with the rows it wrote when the client says.
---@param process dbquery.Process
---@return string
function M.summary(process)
  local seconds = string.format("%.2fs", process:elapsed())
  if process.status == "ok" and process.rows then
    return string.format("%d rows in %s", process.rows, seconds)
  end
  return ENDED[process.status] .. " in " .. seconds
end

local function defineHighlights()
  vim.api.nvim_set_hl(0, HIGHLIGHT.ok, { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, HIGHLIGHT.failed, { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, HIGHLIGHT.cancelled, { link = "DiagnosticHint", default = true })
  vim.api.nvim_set_hl(0, M.ITALIC, { italic = true })
  for status in pairs(BAND) do
    defineBand(status)
  end
end

defineHighlights()
-- Colorschemes clear all groups, so re-apply after a scheme loads.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("db-query.outcome", { clear = true }),
  callback = defineHighlights,
})

local NAMESPACE = vim.api.nvim_create_namespace("db_query_outcome")

vim.api.nvim_set_decoration_provider(NAMESPACE, {
  on_win = function(_, _, buf)
    return vim.b[buf].db_query_log == true
  end,
  on_line = function(_, _, buf, row)
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    for ending, group in pairs(HIGHLIGHT) do
      local icon = M.icon(ending)
      if icon ~= "" and line:sub(1, #icon) == icon then
        vim.api.nvim_buf_set_extmark(buf, NAMESPACE, row, 0, {
          end_col = #line,
          hl_group = group,
          ephemeral = true,
        })
        return
      end
    end
  end,
})

return M
