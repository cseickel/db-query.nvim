--[[
The window a query's output opens in.

The client writes its output to a file and this window shows that file, so the
text is read by nvim and never passes through lua. While the client is still
writing, the file is reloaded on a timer, which is what makes a script's
transcript fill in as it runs.

A pane belongs to the source buffer whose queries it shows, and its window is
placement rather than identity: it is remembered so a second query lands where
the first did, and resolved again whenever that window has gone.
]]

local output = require("db-query.output")

-- This module's own group, so that taking back what it put on a buffer takes
-- back nothing else.
local GROUP = vim.api.nvim_create_augroup("db-query.pane", { clear = true })

---@class dbquery.Pane
---@field srcBuf integer The buffer whose queries this pane shows.
---@field win integer|nil Where the last output opened, while that window lasts.
---@field buf integer|nil What this pane put in that window, which is the output of the last run to reach it.
---@field run dbquery.Run|nil The query whose output this pane is for.
---@field dimmed boolean|nil Whether this pane greyed its window, so that only what it greyed is put back.
---@field timer uv.uv_timer_t|nil Rereading a transcript while it is written.
local Pane = {}
Pane.__index = Pane

-- Slow enough that a client writing steadily does not reread on every write,
-- fast enough to read as live.
local REFRESH = 500

-- Comment is the one group every colorscheme dims, which is what output from
-- the run before this one has to look like.
local STALE = "Normal:Comment,NormalNC:Comment"

---@param srcBuf integer
---@return dbquery.Pane
function Pane.new(srcBuf)
  return setmetatable({ srcBuf = srcBuf }, Pane)
end

--- The window a new pane splits from: the one the query was typed in wherever
--- that is still on screen, and the current window when the source buffer is
--- not displayed at all.
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

--- Rereads `buf` from disk. A window whose cursor was on the last line follows
--- the file down.
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

--- Shows the file at `path`, opening a window below the query if the last one
--- has been closed. The current window does not change.
---
--- A path the user named is one they can ask for again, and the buffer that
--- read it the last time is still holding what it read, so `:edit` is run on
--- it. That is a plain reread for a plain file, and the refresh a plugin that
--- renders this kind of file offers, since a read command fired on a buffer it
--- has already taken over is how such a plugin is told to render again.
---
--- `checktime` would not do: it passes over every buffer whose buftype is set,
--- which is every buffer one of those plugins has taken over.
---
--- The buffer this plugin names is new every run and has nothing to reread.
---@param path string
---@param db string|nil The connection the file came from, for the buffer to carry.
---@return integer buf
function Pane:show(path, db)
  -- Named and then shown by number, because a path put into an :edit command
  -- has to be escaped and a buffer number does not.
  local buf = vim.fn.bufadd(path)
  local shownBefore = vim.api.nvim_buf_is_loaded(buf)

  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_set_buf(self.win, buf)
  else
    self.win = vim.api.nvim_open_win(buf, false, { split = "below", win = parentOf(self.srcBuf) })
  end

  if shownBefore then
    -- In the window it is shown in, since a plugin that renders this file sets
    -- up the window it renders into. Nothing else is set here, since whatever
    -- owns the buffer set what it wanted the first time it read it.
    vim.api.nvim_win_call(self.win, function()
      vim.cmd("edit!")
    end)
  end

  -- Opening at the bottom is what sets the file following itself.
  vim.api.nvim_win_set_cursor(self.win, { vim.api.nvim_buf_line_count(buf), 0 })

  -- Output is aligned in columns, so wrapping would break a row across screen
  -- lines and unalign it, and a line number counts nothing the reader wants.
  vim.wo[self.win].wrap = false
  vim.wo[self.win].number = false
  vim.wo[self.win].relativenumber = false

  -- autoread so a reload while the client is still writing needs no answer.
  vim.bo[buf].autoread = true
  vim.b[buf].db = db

  self.buf = buf
  self:undim()

  -- Whether this file is deleted with the window can have changed since this
  -- buffer last held one, so what was decided then is taken back first.
  vim.api.nvim_clear_autocmds({ group = GROUP, buffer = buf })

  -- A file this plugin clears up goes when the window moves on, since it
  -- outlives nvim otherwise and one query's output can be larger than
  -- everything else in the cache put together. A file that is kept is an
  -- ordinary file, so its buffer is left to whatever `hidden` says, as any file
  -- the user opened would be. `unload` and its neighbours throw away unsaved
  -- changes without asking, which is not this plugin's to do to a file it is
  -- not deleting.
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

--- Whether `buf` is the output this pane put in its window.
---@param buf integer
---@return boolean
function Pane:shows(buf)
  return self.buf == buf
end

--- Greys the output of the run before this one, so that what is on screen while
--- a query runs does not read as that query's result. Only what this pane put
--- in the window, since the window can be given another buffer to show.
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

--- Puts back what `dim` greyed, and leaves a window it never greyed as it is.
function Pane:undim()
  if self.dimmed and self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.wo[self.win].winhighlight = ""
  end
  self.dimmed = false
end

--- Stops rereading, which is all a pane does of its own accord.
function Pane:unfollow()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
end

--- Gives up on the query this pane was for, leaving whatever is on screen
--- where it is.
---
--- A cancel is a request, so a replaced query is still running and still ends
--- in its own time. This is what stops it from opening a window, or taking one
--- back from the query that replaced it.
function Pane:stop()
  self:unfollow()
  self:undim()
  self.run = nil
end

--- Shows `run`'s file while it is still being written, and once more when it
--- ends. The window stays shut until the file has something in it, so a query
--- that prints nothing opens nothing.
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
  -- Ungreyed first, since the query it says is running has ended, and since
  -- what follows can throw.
  run:onFinish(function()
    if self.run == run then
      self:unfollow()
      self:undim()
    end
    refresh()
  end)
end

--- Puts `run`'s output on screen, in place of whatever this pane was showing.
---
--- A transcript is worth watching fill in, so the window follows the file as it
--- is written. Rows are worth reading only once they are all there, and
--- rendering a half written table every half second is expensive on exactly
--- the results large enough to need the wait. An export that failed shows the
--- client's message in place of the rows, and one that was cancelled was
--- stopped by the person who would be reading it.
---@param run dbquery.Run
function Pane:display(run)
  self:stop()
  self.run = run
  -- What the window shows is the run before this one until this one replaces
  -- it, which for an export is not until the end.
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
