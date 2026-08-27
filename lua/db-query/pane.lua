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

---@class dbquery.Pane
---@field srcBuf integer The buffer whose queries this pane shows.
---@field win integer|nil Where the last output opened, while that window lasts.
---@field run dbquery.Run|nil The query whose output this pane is for.
---@field timer uv.uv_timer_t|nil Rereading a transcript while it is written.
local Pane = {}
Pane.__index = Pane

-- Slow enough that a client writing steadily does not reread on every write,
-- fast enough to read as live.
local REFRESH = 500

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
---@param path string
---@param db string|nil The connection the file came from, for the buffer to carry.
---@return integer buf
function Pane:show(path, db)
  -- Named and then shown by number, because a path put into an :edit command
  -- has to be escaped and a buffer number does not.
  local buf = vim.fn.bufadd(path)

  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_set_buf(self.win, buf)
  else
    self.win = vim.api.nvim_open_win(buf, false, { split = "below", win = parentOf(self.srcBuf) })
  end

  -- Opening at the bottom is what sets the file following itself.
  vim.api.nvim_win_set_cursor(self.win, { vim.api.nvim_buf_line_count(buf), 0 })

  -- Output is aligned in columns, so wrapping would break a row across screen
  -- lines and unalign it, and a line number counts nothing the reader wants.
  vim.wo[self.win].wrap = false
  vim.wo[self.win].number = false
  vim.wo[self.win].relativenumber = false

  -- autoread so a reload while the client is still writing needs no answer,
  -- wipe so the output of one query goes when the next one takes the window.
  vim.bo[buf].autoread = true
  vim.bo[buf].bufhidden = "wipe"

  vim.b[buf].db = db

  -- The file outlives nvim otherwise, and one query's output can be larger
  -- than everything else in the cache directory put together.
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      os.remove(path)
    end,
  })
  return buf
end

--- Cuts `buf` loose from the file it read, so that a saved session does not
--- come back to a path that was deleted with the buffer. `:mksession` skips a
--- window only when its buffer is `nofile`, and writes it as a blank one when
--- `blank` is in `sessionoptions`.
---
--- Only once nothing is going to reread it, because checktime ignores every
--- buffer that has a buftype at all, and a transcript would stop filling in.
---@param buf integer|nil
local function seal(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].buftype = "nofile"
  end
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
  self.run = nil
end

--- Shows `run`'s file while it is still being written, and once more when it
--- ends. The window stays shut until the file has something in it, so a query
--- that prints nothing opens nothing.
---@param run dbquery.Run
function Pane:follow(run)
  local buf

  local function refresh()
    if self.run ~= run then
      return
    end
    if not buf then
      local stat = vim.uv.fs_stat(run.path)
      if stat and stat.size > 0 then
        buf = self:show(run.path, run.url)
      end
      return
    end
    if vim.api.nvim_buf_is_valid(buf) then
      reread(buf)
    end
  end

  self.timer = vim.uv.new_timer()
  self.timer:start(REFRESH, REFRESH, vim.schedule_wrap(refresh))
  run:onFinish(function()
    if self.run == run then
      self:unfollow()
    end
    refresh()
    seal(buf)
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

  if run.mode == "script" then
    return self:follow(run)
  end
  run:onFinish(function()
    if self.run == run and run.status ~= "cancelled" then
      seal(self:show(run.path, run.url))
    end
  end)
end

return Pane
