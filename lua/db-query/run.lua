--[[
A running query.

The client writes directly to a file; nvim reads that file. This keeps large
result sets out of lua memory.

A Run holds the process, output path, and status. Interested parties subscribe
via onFinish().
]]

local client = require("db-query.client")
local output = require("db-query.output")

---@alias dbquery.Status "running"|"ok"|"failed"|"cancelled"

---@class dbquery.Run
---@field url string|nil Original connection (for b:db).
---@field resolved string Resolved connection (may include password).
---@field sql string
---@field mode dbquery.Mode
---@field path string Output file path.
---@field status dbquery.Status
---@field started integer hrtime nanoseconds.
---@field job vim.SystemObj
---@field sessionFile string|nil Backend pid file for server-side cancel.
---@field asked boolean Cancel already requested.
---@field subscribers fun(run: dbquery.Run)[]
local Run = {}
Run.__index = Run

---@type dbquery.Run[]
local live = {}

local GROUP = vim.api.nvim_create_augroup("db-query.run", { clear = true })

-- Kill running clients on exit; detached processes don't die with nvim.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = GROUP,
  callback = function()
    for _, run in ipairs(live) do
      run.job:kill("sigterm")
    end
    live = {}
  end,
})

---@param argument string
---@return string
local function quoted(argument)
  return "'" .. argument:gsub("'", "'\\''") .. "'"
end

--- Wraps `argv` to redirect stdout to `path`. Uses `exec` so signals reach the
--- client directly. For transcripts, stderr is merged with stdout.
---@param argv string[]
---@param path string
---@param transcript boolean
---@return string[]
local function writingTo(argv, path, transcript)
  local words = {}
  for _, argument in ipairs(argv) do
    table.insert(words, quoted(argument))
  end
  local line = table.concat(words, " ")
  -- Line-buffer output so scripts show progress.
  if vim.fn.executable("stdbuf") == 1 then
    line = "stdbuf -oL " .. line
  end
  line = "exec " .. line .. " >" .. quoted(path)
  return { "sh", "-c", transcript and (line .. " 2>&1") or line }
end

---@return number
function Run:elapsed()
  return (vim.uv.hrtime() - self.started) / 1e9
end

---@param self dbquery.Run
local function forget(self)
  for index, run in ipairs(live) do
    if run == self then
      table.remove(live, index)
      return
    end
  end
end

---@param self dbquery.Run
---@param code integer
---@return dbquery.Status
local function outcome(self, code)
  if code == 0 then
    return "ok"
  end
  return self.asked and "cancelled" or "failed"
end

---@param path string
---@param text string
---@param mode "a"|"w"
local function writeTo(path, text, mode)
  local file = io.open(path, mode)
  if file then
    file:write(text)
    file:close()
  end
end

--- Handles process exit: writes footer/error, updates status, notifies subscribers.
---@param self dbquery.Run
---@param result vim.SystemCompleted
local function finish(self, result)
  local status = outcome(self, result.code)
  local footer =
    string.format("\n[%s in %.3fs]\n", status == "ok" and "finished" or status, self:elapsed())

  if self.mode == "script" then
    writeTo(self.path, footer, "a")
  elseif status == "failed" then
    writeTo(self.path, vim.trim(result.stderr or "") .. footer, "w")
  elseif status == "cancelled" then
    os.remove(self.path)
  end

  vim.schedule(function()
    self.status = status
    forget(self)
    if self.sessionFile then
      os.remove(self.sessionFile)
    end

    for _, subscriber in ipairs(self.subscribers) do
      local ok, err = pcall(subscriber, self)
      if not ok then
        vim.notify("db-query: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end)
end

---@class dbquery.RunSpec
---@field url string|nil
---@field resolved string
---@field sql string
---@field mode dbquery.Mode
---@field srcName string Source buffer name (for output file naming).
---@field outputPath string|nil User-specified output path.

--- Starts the client process. Returns nil on invalid url or cancelled output.
---@param spec dbquery.RunSpec
---@return dbquery.Run|nil
function Run.start(spec)
  local command = client.command(spec.resolved, spec.sql, spec.mode)
  if not command then
    return nil
  end

  local path = output.path(spec.srcName, command.extension, spec.outputPath)
  if not path then
    return nil
  end

  local self = setmetatable({
    url = spec.url,
    resolved = spec.resolved,
    sql = spec.sql,
    mode = spec.mode,
    path = path,
    status = "running",
    started = vim.uv.hrtime(),
    sessionFile = command.sessionFile,
    asked = false,
    subscribers = {},
  }, Run)

  self.job = vim.system(writingTo(command.argv, self.path, spec.mode == "script"), {
    text = true,
    env = command.env,
    stdin = command.stdin,
    -- Own process group so cancel signals don't hit nvim.
    detach = true,
  }, function(result)
    finish(self, result)
  end)

  table.insert(live, self)
  return self
end

--- Registers `subscriber` to be called when the run finishes. If already
--- finished, calls immediately.
---@param subscriber fun(run: dbquery.Run)
function Run:onFinish(subscriber)
  if self.status == "running" then
    table.insert(self.subscribers, subscriber)
  else
    subscriber(self)
  end
end

--- Requests cancellation via server-side cancel or SIGINT. The run remains
--- active until the client exits.
function Run:cancel()
  if self.asked or self.status ~= "running" then
    return
  end
  self.asked = true
  if not (self.sessionFile and client.cancel(self.resolved, self.sessionFile)) then
    self.job:kill("sigint")
  end
end

return Run
