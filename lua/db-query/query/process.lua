--[[
Runs a client process and reports how it ended.
]]

local mainloop = require("db-query.mainloop")

---@alias dbquery.Status "running"|"ok"|"failed"|"cancelled"

---@class dbquery.Process
---@field status dbquery.Status
---@field started integer hrtime nanoseconds.
---@field finished integer|nil hrtime nanoseconds, set when the process exits.
---@field rows integer|nil Rows the client reported writing, for a client that records them in `command.countFile`, or 0 once the run finds its results file empty.
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

-- A detached process doesn't die with nvim.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("db-query.query.process", { clear = true }),
  callback = function()
    for _, process in ipairs(live) do
      process.job:kill("sigterm")
    end
    live = {}
  end,
})

--- Returns the number a client wrote to `file`, or nil when it has not.
---@param file string
---@return integer|nil
function Process.recorded(file)
  local handle = io.open(file, "r")
  if not handle then
    return nil
  end
  local text = handle:read("*a")
  handle:close()
  return tonumber(text:match("%d+"))
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
    local finished = vim.uv.hrtime()
    mainloop.run(function()
      self.result = result
      self.finished = finished
      -- A client killed by a signal exits with code 0, so the signal decides too.
      if result.code == 0 and result.signal == 0 then
        self.status = "ok"
      else
        self.status = self.asked and "cancelled" or "failed"
      end
      for index, process in ipairs(live) do
        if process == self then
          table.remove(live, index)
          break
        end
      end
      if spawn.command.sessionFile then
        os.remove(spawn.command.sessionFile)
      end
      local countFile = spawn.command.countFile
      if countFile then
        self.rows = Process.recorded(countFile)
        os.remove(countFile)
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

--- Returns seconds from start to exit, or to now while the process runs.
---@return number
function Process:elapsed()
  return ((self.finished or vim.uv.hrtime()) - self.started) / 1e9
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
