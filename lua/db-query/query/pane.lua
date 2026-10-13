--[[
Shows a sql buffer's query output in a split window.
]]

local mainloop = require("db-query.mainloop")

---@class dbquery.Pane
---@field source dbquery.Source Whose `run` is the one the pane follows.
---@field path string|nil The file last put on screen.
---@field stopRefresh fun()|nil Stops reloading the log, nil while nothing reloads it.
local Pane = {}
Pane.__index = Pane

local REFRESH_MS = 500

--- The sql buffer each output buffer was shown for.
---@type table<integer, integer>
local owners = {}

---@param source dbquery.Source
---@return dbquery.Pane
function Pane.new(source)
  return setmetatable({ source = source }, Pane)
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
--- nil when none matches.
---@param tab integer
---@param buf integer
---@param run dbquery.Run
---@return integer|nil
local function targetOf(tab, buf, run)
  local sqlBuf = run.ctx.buf
  local logBuf = vim.fn.bufadd(run.log.path)
  return findWin(tab, function(shown)
    return shown == buf
  end) or findWin(tab, function(shown)
    return owners[shown] == sqlBuf and (shown == logBuf) == (buf == logBuf)
  end) or findWin(tab, function(shown)
    return owners[shown] == sqlBuf
  end) or findWin(tab, function(shown)
    return owners[shown] ~= nil
  end)
end

---@class dbquery.ShowOpts
---@field tail? boolean Put the cursor on the last line, for a file still being written to.
---@field tab? integer The tabpage to show it in, the current one by default.

--- Opens one of `run`'s files in an output window of the tabpage, opening a
--- split below the sql buffer when there is none.
---@param run dbquery.Run
---@param path string
---@param opts? dbquery.ShowOpts
function Pane:show(run, path, opts)
  opts = opts or {}
  local tab = opts.tab and vim.api.nvim_tabpage_is_valid(opts.tab) and opts.tab
    or vim.api.nvim_get_current_tabpage()
  local buf = vim.fn.bufadd(path)
  local shownBefore = vim.api.nvim_buf_is_loaded(buf)
  local sqlBuf = run.ctx.buf

  local win = targetOf(tab, buf, run)
  if win then
    vim.api.nvim_win_set_buf(win, buf)
  else
    -- Split from the tab's current window when it shows the sql buffer, else
    -- from another showing it, else from the first split.
    local parent = vim.api.nvim_tabpage_get_win(tab)
    if not (isSplit(parent) and vim.api.nvim_win_get_buf(parent) == sqlBuf) then
      parent = assert(findWin(tab, function(shown)
        return shown == sqlBuf
      end) or findWin(tab, function()
        return true
      end), "a tabpage always has a split window")
    end
    win = vim.api.nvim_open_win(buf, false, { split = "below", win = parent })
  end

  if owners[buf] == nil then
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        owners[buf] = nil
      end,
    })
  end
  owners[buf] = sqlBuf
  if self.source.progress then
    self.source.progress:bind(buf)
  end

  -- Reloads a file shown before with `:edit!`, because `checktime` does nothing
  -- in a buffer with a `buftype`, such as csv-table's.
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
  -- Listed like any file the user opened, so one left on screen is kept.
  vim.bo[buf].buflisted = true
  vim.b[buf].db = run.ctx.url
  vim.b[buf].db_name = run.ctx.connectionName
  vim.b[buf].db_query_log = path == run.log.path

  self.path = path
end

--- Returns the loaded buffers this sql buffer's output was shown in.
---@return integer[]
function Pane:outputs()
  local outputs = {}
  for buf, sqlBuf in pairs(owners) do
    if sqlBuf == self.source.buf and vim.api.nvim_buf_is_loaded(buf) then
      table.insert(outputs, buf)
    end
  end
  return outputs
end

--- Closes every window in the current tabpage that shows this sql buffer's
--- output.
function Pane:close()
  local tab = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    -- An autocmd run by closing one window may have closed the next.
    local valid = vim.api.nvim_win_is_valid(win)
    if valid and isSplit(win) and owners[vim.api.nvim_win_get_buf(win)] == self.source.buf then
      -- nvim refuses to close the last window, which leaves it open.
      pcall(vim.api.nvim_win_close, win, false)
    end
  end
end

--- Stops reloading the log, leaving the window as it is.
function Pane:stop()
  if self.stopRefresh then
    self.stopRefresh()
    self.stopRefresh = nil
  end
end

--- Follows `run` in the current tabpage, ending on its rows or on its log.
---
--- Rows already on screen are left there while the query runs, so a rerun does
--- not take away what you were reading. The spinner in the sql buffer, and in
--- the output window's winbar, is what says a query is under way. Otherwise the
--- log opens straight away and reloads every REFRESH_MS, so a long query fills
--- in as it goes.
---
--- The output ends on the rows when the query returned any, and on the log
--- otherwise, with the reason at the bottom. Both go to the tabpage the query
--- started in, even when you have moved to another by the time it finishes.
---@param run dbquery.Run
function Pane:display(run)
  self:stop()

  local tab = vim.api.nvim_get_current_tabpage()
  local logBuf = vim.fn.bufadd(run.log.path)
  local rowsHeld = findWin(tab, function(shown)
    return owners[shown] == run.ctx.buf and shown ~= logBuf
  end)
  if not rowsHeld then
    self:show(run, run.log.path, { tail = true, tab = tab })
  end

  self.stopRefresh = mainloop.every(REFRESH_MS, function()
    if self.source.run ~= run or not vim.api.nvim_buf_is_loaded(logBuf) then
      return
    end
    -- Cursors at the end of the log stay at the end as it grows.
    local lineCount = vim.api.nvim_buf_line_count(logBuf)
    local following = {}
    for _, win in ipairs(vim.fn.win_findbuf(logBuf)) do
      following[win] = vim.api.nvim_win_get_cursor(win)[1] == lineCount
    end
    vim.cmd("checktime " .. logBuf)
    local bottom = vim.api.nvim_buf_line_count(logBuf)
    for win, follows in pairs(following) do
      if follows and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_cursor(win, { bottom, 0 })
      end
    end
  end)

  run.process:onFinish(function()
    if self.source.run ~= run then
      return
    end
    self:stop()
    if run.process.status == "ok" and run.path and not run.empty then
      self:show(run, run.path, { tab = tab })
    else
      self:show(run, run.log.path, { tail = true, tab = tab })
    end
  end)
end

return Pane
