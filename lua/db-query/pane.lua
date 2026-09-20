--[[
Output window management.

A pane belongs to a source buffer and shows query output in a split window.
The client writes to a file and nvim reads that file. The log is shown while
the query runs, reloaded on a timer, and gives way to the rows when they arrive.

Output files open as ordinary listed buffers, so leaving one on screen keeps
it. Deleting them is `Source:close`'s job, since the run that wrote a file
outlives the window that showed it.
]]

local main = require("db-query.main")

---@class dbquery.Pane
---@field win integer|nil
---@field buf integer|nil
---@field path string|nil File the window is showing.
---@field run dbquery.Run|nil
---@field timer uv.uv_timer_t|nil
local Pane = {}
Pane.__index = Pane

local REFRESH = 500

---@return dbquery.Pane
function Pane.new()
  return setmetatable({}, Pane)
end

--- Returns the window to split from: a window showing `srcBuf`, or current.
---@param srcBuf integer
---@return integer
local function parentOf(srcBuf)
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(current) == srcBuf then
    return current
  end
  local showing = vim.fn.win_findbuf(srcBuf)
  return showing[1] or current
end

--- Reloads `buf` from disk, keeping cursors that were at EOF at EOF.
---@param buf integer
local function reread(buf)
  local count = vim.api.nvim_buf_line_count(buf)
  local following = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    following[win] = vim.api.nvim_win_get_cursor(win)[1] == count
  end

  vim.cmd("checktime " .. buf)

  local bottom = vim.api.nvim_buf_line_count(buf)
  for win, follows in pairs(following) do
    if follows and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { bottom, 0 })
    end
  end
end

--- Opens one of `run`'s files in the pane's window, creating the window if
--- needed. `tail` puts the cursor on the last line, for a file still being
--- written to.
---
--- For previously-shown paths, runs `:edit!` to reload (needed for buftype
--- buffers like csv-table, where checktime is a no-op).
---@param run dbquery.Run
---@param path string
---@param tail boolean
---@return integer buf
function Pane:show(run, path, tail)
  local buf = vim.fn.bufadd(path)
  local shownBefore = vim.api.nvim_buf_is_loaded(buf)

  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_set_buf(self.win, buf)
  else
    self.win = vim.api.nvim_open_win(buf, false, { split = "below", win = parentOf(run.ctx.buf) })
  end

  if tail then
    if shownBefore then
      vim.api.nvim_win_call(self.win, function()
        vim.cmd("edit!")
        local row = vim.api.nvim_buf_line_count(buf) or 1
        vim.api.nvim_win_set_cursor(self.win, { row, 0 })
      end)
    end
  end
  vim.wo[self.win].wrap = false
  vim.wo[self.win].number = false
  vim.wo[self.win].relativenumber = false

  vim.bo[buf].autoread = true
  vim.bo[buf].buflisted = true
  vim.b[buf].db = run.ctx.url
  vim.b[buf].db_name = run.ctx.name

  self.buf = buf
  self.path = path
  return buf
end

---@param buf integer
---@return boolean
function Pane:shows(buf)
  return self.buf == buf
end

--- Returns the file in the window, or nil before the first query.
---@return string|nil
function Pane:showing()
  return self.path
end

--- Stops the reload timer.
function Pane:unfollow()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
end

--- Disconnects from the current run without affecting the window contents.
function Pane:stop()
  self:unfollow()
  self.run = nil
end

--- Follows `run` in the window, ending on its rows or on its log.
---
--- Rows already on screen are left there while the query runs, so a rerun does
--- not take away what you were reading. The spinner in the sql buffer, and in
--- the output window's winbar, is what says a query is under way. Otherwise the
--- log opens straight away and reloads every REFRESH ms, so a long query fills
--- in as it goes.
---
--- The window ends on the rows when the query returned any, and on the log
--- otherwise, with the reason at the bottom.
---@param run dbquery.Run
function Pane:display(run)
  self:stop()
  self.run = run

  local held = self.win and vim.api.nvim_win_is_valid(self.win) and self.path
  if not (held and held ~= run.log.path) then
    self:show(run, run.log.path, true)
  end

  local function refresh()
    if self.run == run and self.buf and vim.api.nvim_buf_is_valid(self.buf) then
      reread(self.buf)
    end
  end

  self.timer = vim.uv.new_timer()
  self.timer:start(REFRESH, REFRESH, main.frame(refresh))

  run.process:onFinish(function()
    if self.run ~= run then
      return
    end
    self:unfollow()
    if run.process.status == "ok" and run.path then
      self:show(run, run.path, false)
    else
      self:show(run, run.log.path, true)
    end
  end)
end

return Pane
