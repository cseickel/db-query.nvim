--[[
A running client process: a query, or a statement whose output comes back into
lua, such as a connection test.

A Process holds the job, when it started, and how it ended. Interested parties
subscribe with onFinish(). Every process still running when nvim exits is
killed, because a detached process does not die with nvim.
]]

local main = require("db-query.main")

---@alias dbquery.Status "running"|"ok"|"failed"|"cancelled"

---@class dbquery.Process
---@field status dbquery.Status
---@field started integer hrtime nanoseconds.
---@field job vim.SystemObj
---@field result vim.SystemCompleted|nil How the process exited, set when `status` leaves "running".
---@field askServer fun(): boolean Asks the server to cancel, returning false when it cannot be asked.
---@field asked boolean Cancel already requested.
---@field timeout integer|nil Milliseconds before the process is killed, nil when it waits.
---@field subscribers fun(process: dbquery.Process, result: vim.SystemCompleted)[]
local Process = {}
Process.__index = Process

---@class dbquery.Spawn
---@field command dbquery.Command
---@field argv string[]|nil What to run in place of `command.argv`, such as a shell wrapping it.
---@field timeout integer|nil Milliseconds before the process is killed, nil to wait for it.
---@field askServer fun(): boolean

---@type dbquery.Process[]
local live = {}

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("db-query.process", { clear = true }),
  callback = function()
    for _, process in ipairs(live) do
      process.job:kill("sigterm")
    end
    live = {}
  end,
})

---@param self dbquery.Process
local function forget(self)
  for index, process in ipairs(live) do
    if process == self then
      table.remove(live, index)
      return
    end
  end
end

--- A client killed by a signal exits with code 0, so the signal decides too.
---@param self dbquery.Process
---@param result vim.SystemCompleted
---@return dbquery.Status
local function outcome(self, result)
  if result.code == 0 and result.signal == 0 then
    return "ok"
  end
  return self.asked and "cancelled" or "failed"
end

--- Starts the client in its own process group, so a cancel signal does not
--- reach nvim, with stdout and stderr captured as text. Returns nil and the
--- reason when the process cannot start, such as a missing executable.
---@param spawn dbquery.Spawn
---@return dbquery.Process|nil
---@return string|nil
function Process.start(spawn)
  local self = setmetatable({
    status = "running",
    started = vim.uv.hrtime(),
    askServer = spawn.askServer,
    asked = false,
    timeout = spawn.timeout,
    subscribers = {},
  }, Process)

  local started, job = pcall(vim.system, spawn.argv or spawn.command.argv, {
    text = true,
    env = spawn.command.env,
    stdin = spawn.command.stdin,
    detach = true,
    timeout = spawn.timeout,
  }, function(result)
    main.run(function()
      self.result = result
      self.status = outcome(self, result)
      forget(self)
      if spawn.command.sessionFile then
        os.remove(spawn.command.sessionFile)
      end
      for _, subscriber in ipairs(self.subscribers) do
        local ok, err = pcall(subscriber, self, result)
        if not ok then
          vim.notify("db-query: " .. tostring(err), vim.log.levels.ERROR)
        end
      end
    end)
  end)
  if not started then
    return nil, tostring(job)
  end

  self.job = job
  table.insert(live, self)
  return self
end

---@return number
function Process:elapsed()
  return (vim.uv.hrtime() - self.started) / 1e9
end

--- Calls `subscriber` with how the process exited when it finishes, or at once
--- when it already has.
---@param subscriber fun(process: dbquery.Process, result: vim.SystemCompleted)
function Process:onFinish(subscriber)
  local result = self.result
  if result then
    subscriber(self, result)
  else
    table.insert(self.subscribers, subscriber)
  end
end

--- Returns why a finished process did not succeed, or nil when it succeeded or
--- is still running. vim.system exits a process it killed for its timeout with
--- code 124.
---@return string|nil
function Process:reason()
  if self.status == "ok" or self.status == "running" then
    return nil
  end
  if self.status == "cancelled" then
    return "cancelled"
  end
  local result = self.result
  if result.code == 124 and self.timeout then
    return "no answer in " .. self.timeout / 1000 .. " seconds"
  end
  local printed = vim.trim(result.stderr or "")
  return printed ~= "" and printed or ("exit " .. result.code .. ", signal " .. result.signal)
end

--- Asks the server to cancel when it can be asked, and sends SIGINT to the
--- client otherwise. The process stays `running` until the client exits.
function Process:cancel()
  if self.asked or self.status ~= "running" then
    return
  end
  self.asked = true
  if not self.askServer() then
    self.job:kill("sigint")
  end
end

return Process
