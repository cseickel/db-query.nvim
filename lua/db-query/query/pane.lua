--[[
Output window management.

A pane belongs to a source buffer and shows query output in a split window.
The client writes to a file and nvim reads that file. The log is shown while
the query runs, reloaded on a timer, and gives way to the rows when they arrive.

Output goes to a window already showing output, preferring this sql buffer's own,
and a new split opens only when the tabpage has none. The log and the rows
stay in separate windows once you put them there.

Output files open as ordinary listed buffers, so leaving one on screen keeps
it. Deleting them is `Source:close`'s job, since the run that wrote a file
outlives the window that showed it.
]]

local main = require("db-query.mainloop")

---@class dbquery.Pane
---@field path string|nil The file last put on screen.
---@field run dbquery.Run|nil
---@field timer uv.uv_timer_t|nil
local Pane = {}
Pane.__index = Pane

local REFRESH = 500

--- The sql buffer each output buffer was shown for.
---@type table<integer, integer>
local owners = {}

---@return dbquery.Pane
function Pane.new()
  return setmetatable({}, Pane)
end

--- Returns the sql buffer that `buf` was shown as output for, or nil when
--- `buf` is not an output buffer.
---@param buf integer
---@return integer|nil
function Pane.owner(buf)
  return owners[buf]
end

---@param win integer
---@return boolean
local function isSplit(win)
  return vim.api.nvim_win_get_config(win).relative == ""
end

--- Returns the first split window in `tab` whose buffer satisfies `match`.
---@param tab integer
---@param match fun(buf: integer): boolean
---@return integer|nil
local function findWin(tab, match)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if isSplit(win) and match(vim.api.nvim_win_get_buf(win)) then
      return win
    end
  end
  return nil
end

--- Returns the window in `tab` to show `buf`, one of `run`'s files, in. The
--- first match wins: a window already showing `buf`, one showing the same kind
--- of output (log or rows) from the same sql buffer, one showing any output
--- from the same sql buffer, and one showing any sql buffer's output. Returns
--- nil when none matches, so the caller opens a split.
---@param tab integer
---@param buf integer
---@param run dbquery.Run
---@return integer|nil
local function targetOf(tab, buf, run)
  local src = run.ctx.buf
  local logBuf = vim.fn.bufadd(run.log.path)
  return findWin(tab, function(b)
    return b == buf
  end) or findWin(tab, function(b)
    return owners[b] == src and (b == logBuf) == (buf == logBuf)
  end) or findWin(tab, function(b)
    return owners[b] == src
  end) or findWin(tab, function(b)
    return owners[b] ~= nil
  end)
end

--- Returns the window in `tab` to split from: the tab's current window when it
--- shows `srcBuf`, else another showing `srcBuf`, else the first split.
---@param tab integer
---@param srcBuf integer
---@return integer
local function parentOf(tab, srcBuf)
  local current = vim.api.nvim_tabpage_get_win(tab)
  if isSplit(current) and vim.api.nvim_win_get_buf(current) == srcBuf then
    return current
  end
  local showing = findWin(tab, function(b)
    return b == srcBuf
  end) or findWin(tab, function()
    return true
  end)
  return assert(showing, "a tabpage always has a split window")
end

--- Records `buf` as output of `srcBuf`, forgetting it when the buffer is wiped.
---@param buf integer
---@param srcBuf integer
local function own(buf, srcBuf)
  if owners[buf] == nil then
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        owners[buf] = nil
      end,
    })
  end
  owners[buf] = srcBuf
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

---@class dbquery.ShowOpts
---@field tail? boolean Put the cursor on the last line, for a file still being written to.
---@field tab? integer The tabpage to show it in, the current one by default.

--- Opens one of `run`'s files in an output window of the tabpage, opening a
--- split below the sql buffer when there is none.
---
--- For previously-shown paths, runs `:edit!` to reload (needed for buftype
--- buffers like csv-table, where checktime is a no-op).
---@param run dbquery.Run
---@param path string
---@param opts? dbquery.ShowOpts
function Pane:show(run, path, opts)
  opts = opts or {}
  local tab = opts.tab and vim.api.nvim_tabpage_is_valid(opts.tab) and opts.tab
    or vim.api.nvim_get_current_tabpage()
  local buf = vim.fn.bufadd(path)
  local shownBefore = vim.api.nvim_buf_is_loaded(buf)

  local win = targetOf(tab, buf, run)
  if win then
    vim.api.nvim_win_set_buf(win, buf)
  else
    win = vim.api.nvim_open_win(buf, false, { split = "below", win = parentOf(tab, run.ctx.buf) })
  end
  own(buf, run.ctx.buf)

  if opts.tail and shownBefore then
    vim.api.nvim_win_call(win, function()
      vim.cmd("edit!")
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    end)
  end
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false

  vim.bo[buf].autoread = true
  vim.bo[buf].buflisted = true
  vim.b[buf].db = run.ctx.url
  vim.b[buf].db_name = run.ctx.name
  vim.b[buf].db_query_log = path == run.log.path

  self.path = path
end

--- Returns the file last put on screen, or nil before the first query.
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

--- Follows `run` in the current tabpage, ending on its rows or on its log.
---
--- Rows already on screen are left there while the query runs, so a rerun does
--- not take away what you were reading. The spinner in the sql buffer, and in
--- the output window's winbar, is what says a query is under way. Otherwise the
--- log opens straight away and reloads every REFRESH ms, so a long query fills
--- in as it goes.
---
--- The output ends on the rows when the query returned any, and on the log
--- otherwise, with the reason at the bottom. Both go to the tabpage the query
--- started in, even when you have moved to another by the time it finishes.
---@param run dbquery.Run
function Pane:display(run)
  self:stop()
  self.run = run

  local tab = vim.api.nvim_get_current_tabpage()
  local logBuf = vim.fn.bufadd(run.log.path)
  local rowsHeld = findWin(tab, function(b)
    return owners[b] == run.ctx.buf and b ~= logBuf
  end)
  if not rowsHeld then
    self:show(run, run.log.path, { tail = true, tab = tab })
  end

  local function refresh()
    if self.run == run and vim.api.nvim_buf_is_loaded(logBuf) then
      reread(logBuf)
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
      self:show(run, run.path, { tab = tab })
    else
      self:show(run, run.log.path, { tail = true, tab = tab })
    end
  end)
end

return Pane
