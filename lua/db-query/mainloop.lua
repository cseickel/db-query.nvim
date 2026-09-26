--[[
Runs code where nvim allows it to change the editor.

nvim refuses editor changes in a libuv callback (E5560) and under textlock,
while it evaluates a statusline, an `<expr>` mapping, or a completion function
(E565). Code entered from outside the plugin, such as a process exiting, a
timer, a `vim.ui` choice, or a public function, goes through this module, and
the code behind it calls vim directly.
]]

local M = {}

--- Milliseconds between checks while nvim still refuses changes. A retry
--- through `vim.schedule` would run in the same pass over nvim's event queue,
--- and repeat forever without nvim reading the key that lifts the lock.
local RETRY_MS = 10

---@type integer|nil
local probeBuf = nil

--- Returns true when nvim refuses editor changes here. No api reports
--- textlock, so an edit of an empty hidden buffer tests for it.
---@return boolean
local function refused()
  if vim.in_fast_event() then
    return true
  end
  if not (probeBuf and vim.api.nvim_buf_is_valid(probeBuf)) then
    local created = pcall(function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].undolevels = -1
      -- `nvim -M` starts every buffer unmodifiable, which is not a lock.
      vim.bo[buf].modifiable = true
      probeBuf = buf
    end)
    if not created then
      return true
    end
  end
  return not pcall(vim.api.nvim_buf_set_lines, probeBuf, 0, -1, false, {})
end

---@param fn function
---@param args table Packed by `vim.F.pack_len`.
local function retry(fn, args)
  vim.defer_fn(function()
    if refused() then
      return retry(fn, args)
    end
    fn(vim.F.unpack_len(args))
  end, RETRY_MS)
end

--- Calls `fn(...)` now, or, when nvim refuses editor changes here, as soon as
--- nvim allows them.
---@param fn function
---@param ... any
function M.run(fn, ...)
  if not refused() then
    fn(...)
    return
  end
  local args = vim.F.pack_len(...)
  vim.schedule(function()
    if refused() then
      return retry(fn, args)
    end
    fn(vim.F.unpack_len(args))
  end)
end

--- Returns `fn` as a function that calls it through `run`.
---@param fn function
---@return function
function M.wrap(fn)
  return function(...)
    M.run(fn, ...)
  end
end

--- Calls `read` as soon as nvim allows reading the editor, which is at once
--- anywhere but a libuv callback, then calls `act` through `run` with what
--- `read` returned. A read of the cursor or the current buffer that waited for
--- textlock to lift would see what the keys run after it left behind.
---@param read fun(): ...
---@param act function
function M.capture(read, act)
  if vim.in_fast_event() then
    vim.schedule(function()
      M.capture(read, act)
    end)
    return
  end
  local values = vim.F.pack_len(read())
  M.run(act, vim.F.unpack_len(values))
end

--- Calls `fn` every `ms` milliseconds until the returned function is called.
--- A tick that finds nvim refusing changes is dropped, and so is one that
--- arrives while the last is still waiting to run.
---@param ms integer
---@param fn fun()
---@return fun() stop
function M.every(ms, fn)
  local timer = assert(vim.uv.new_timer())
  local pending = false
  timer:start(ms, ms, function()
    if pending then
      return
    end
    pending = true
    vim.schedule(function()
      pending = false
      if not timer:is_closing() and not refused() then
        fn()
      end
    end)
  end)
  return function()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
end

return M
