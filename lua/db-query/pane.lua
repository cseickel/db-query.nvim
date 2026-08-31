--[[
Output window management.

A pane belongs to a source buffer and shows query results in a split window.
The client writes to a file; nvim reads that file. For scripts, the file is
reloaded on a timer to show progress.
]]

local output = require("db-query.output")

local GROUP = vim.api.nvim_create_augroup("db-query.pane", { clear = true })

---@class dbquery.Pane
---@field srcBuf integer
---@field win integer|nil
---@field buf integer|nil
---@field run dbquery.Run|nil
---@field dimmed boolean|nil
---@field timer uv.uv_timer_t|nil
local Pane = {}
Pane.__index = Pane

local REFRESH = 500

local STALE = "Normal:Comment,NormalNC:Comment"

---@param srcBuf integer
---@return dbquery.Pane
function Pane.new(srcBuf)
  return setmetatable({ srcBuf = srcBuf }, Pane)
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

--- Opens `path` in the pane's window, creating the window if needed.
---
--- For previously-shown paths, runs `:edit!` to reload (needed for buftype
--- buffers like csv-table, where checktime is a no-op).
---@param path string
---@param db string|nil Connection url for b:db.
---@return integer buf
function Pane:show(path, db)
  local buf = vim.fn.bufadd(path)
  local shownBefore = vim.api.nvim_buf_is_loaded(buf)

  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_set_buf(self.win, buf)
  else
    self.win = vim.api.nvim_open_win(buf, false, { split = "below", win = parentOf(self.srcBuf) })
  end

  if shownBefore then
    vim.api.nvim_win_call(self.win, function()
      vim.cmd("edit!")
    end)
  end

  vim.api.nvim_win_set_cursor(self.win, { vim.api.nvim_buf_line_count(buf), 0 })
  vim.wo[self.win].wrap = false
  vim.wo[self.win].number = false
  vim.wo[self.win].relativenumber = false

  vim.bo[buf].autoread = true
  vim.b[buf].db = db

  self.buf = buf
  self:undim()

  vim.api.nvim_clear_autocmds({ group = GROUP, buffer = buf })

  local ours = output.owns(path)
  vim.bo[buf].bufhidden = ours and "wipe" or ""
  if ours then
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = GROUP,
      buffer = buf,
      once = true,
      callback = function()
        os.remove(path)
      end,
    })
  end
  return buf
end

---@param buf integer
---@return boolean
function Pane:shows(buf)
  return self.buf == buf
end

--- Greys the window to indicate stale output from a previous run.
function Pane:dim()
  if
    self.win
    and vim.api.nvim_win_is_valid(self.win)
    and self:shows(vim.api.nvim_win_get_buf(self.win))
  then
    vim.wo[self.win].winhighlight = STALE
    self.dimmed = true
  end
end

--- Restores normal highlighting after dim().
function Pane:undim()
  if self.dimmed and self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.wo[self.win].winhighlight = ""
  end
  self.dimmed = false
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
  self:undim()
  self.run = nil
end

--- Displays `run`'s output with live reloading. Opens the window when the file
--- has content; a query that prints nothing opens nothing.
---@param run dbquery.Run
function Pane:follow(run)
  local shown

  local function refresh()
    if self.run ~= run then
      return
    end
    if not shown then
      local stat = vim.uv.fs_stat(run.path)
      if stat and stat.size > 0 then
        shown = self:show(run.path, run.url)
      end
      return
    end
    if vim.api.nvim_buf_is_valid(shown) then
      reread(shown)
    end
  end

  self.timer = vim.uv.new_timer()
  self.timer:start(REFRESH, REFRESH, vim.schedule_wrap(refresh))
  run:onFinish(function()
    if self.run == run then
      self:unfollow()
      self:undim()
    end
    refresh()
  end)
end

--- Displays `run`'s output, replacing any previous output.
---
--- Scripts use live reloading (follow). Exports wait for completion, then show
--- the result or error; cancelled exports show nothing.
---@param run dbquery.Run
function Pane:display(run)
  self:stop()
  self.run = run
  self:dim()

  if run.mode == "script" then
    return self:follow(run)
  end
  run:onFinish(function()
    if self.run ~= run then
      return
    end
    self:undim()
    if run.status ~= "cancelled" then
      self:show(run.path, run.url)
    end
  end)
end

return Pane
