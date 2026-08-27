--[[
A query in flight.

The client writes what it prints straight to a file and nvim reads that file,
so the output never passes through lua and a result set large enough to exhaust
nvim's memory cannot.

A run knows nothing about buffers or windows. It holds the process, the file it
is writing, and how it ended, and whatever wants to react to it subscribes with
`onFinish`. A run nobody subscribes to is a query with no result on screen,
which is a legitimate thing to want.
]]

local client = require("db-query.client")
local output = require("db-query.output")

---@alias dbquery.Status "running"|"ok"|"failed"|"cancelled"

---@class dbquery.Run
---@field url string|nil The connection as it was written, which is what `b:db` holds.
---@field resolved string The connection the client was given, which may hold a password.
---@field sql string
---@field mode dbquery.Mode
---@field path string The file the client is writing, named for what it holds.
---@field status dbquery.Status
---@field started integer When the client was spawned, as hrtime nanoseconds.
---@field job vim.SystemObj
---@field sessionFile string|nil Where this client writes the server session it holds.
---@field asked boolean Whether a cancel has already been asked for.
---@field subscribers fun(run: dbquery.Run)[]
local Run = {}
Run.__index = Run

-- Every run still going, so nvim leaving can take the clients with it.
---@type dbquery.Run[]
local live = {}

-- This module's own group, registered at require time, which is before `setup`
-- runs and clears the group it makes.
local GROUP = vim.api.nvim_create_augroup("db-query.run", { clear = true })

-- Cancelling leaves the client to end in its own time, which it will not get
-- once nvim is gone, and a detached client does not die with nvim either.
-- Someone will delete this and leave a psql holding a transaction open.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = GROUP,
  callback = function()
    for _, run in ipairs(live) do
      run.job:kill("sigterm")
    end
    live = {}
  end,
})

--- `argument` as one word of a `sh -c` command line.
---@param argument string
---@return string
local function quoted(argument)
  return "'" .. argument:gsub("'", "'\\''") .. "'"
end

--- `argv` as a command line that writes what the client prints to `path`, so
--- the output goes from the client to the file without passing through nvim.
--- `exec` leaves the client holding the shell's own pid, so a signal reaches
--- the client.
---
--- A transcript is read, so the client's errors belong in it in the order the
--- client printed them, and one stream is the only way to get that. Rows are
--- data, and their stderr stays a separate pipe so an error cannot land in the
--- csv.
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
  -- Clients block buffer their output when it is not a terminal, and a long
  -- script would then show nothing until it had finished.
  if vim.fn.executable("stdbuf") == 1 then
    line = "stdbuf -oL " .. line
  end
  line = "exec " .. line .. " >" .. quoted(path)
  return { "sh", "-c", transcript and (line .. " 2>&1") or line }
end

--- How long the client has been running, in seconds.
---@return number
function Run:elapsed()
  return (vim.uv.hrtime() - self.started) / 1e9
end

--- Takes `self` out of the live list.
---@param self dbquery.Run
local function forget(self)
  for index, run in ipairs(live) do
    if run == self then
      table.remove(live, index)
      return
    end
  end
end

--- How the client ended, which a nonzero exit alone does not say: a client
--- that was asked to stop reports the same failure as one that broke.
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

--- Records how the client ended and tells everyone who asked.
---
--- The footer is written before nvim hears about the exit, so the transcript is
--- complete by the time anything rereads it.
---
--- An export that failed wrote no rows and printed why on a stream the rows
--- file never sees, so what it has to show is a transcript of that message.
--- Under its own name, because a csv reader would render an error as a table.
---@param self dbquery.Run
---@param result vim.SystemCompleted
local function finish(self, result)
  local status = outcome(self, result.code)
  local footer =
    string.format("\n[%s in %.3fs]\n", status == "ok" and "finished" or status, self:elapsed())

  if self.mode == "script" then
    writeTo(self.path, footer, "a")
  elseif status == "failed" then
    local transcript = self.path:gsub("%.[^.]+$", ".log")
    writeTo(transcript, vim.trim(result.stderr or "") .. footer, "w")
    os.remove(self.path)
    self.path = transcript
  end

  vim.schedule(function()
    self.status = status
    forget(self)
    if self.sessionFile then
      os.remove(self.sessionFile)
    end

    for _, subscriber in ipairs(self.subscribers) do
      subscriber(self)
    end
  end)
end

---@class dbquery.RunSpec
---@field url string|nil The connection as it was written.
---@field resolved string The connection to hand the client.
---@field sql string
---@field mode dbquery.Mode
---@field srcName string The name of the buffer the sql came from, which names the output file.

--- Starts the client and returns the run it is. Nil for a url no client is
--- known for, already reported.
---@param spec dbquery.RunSpec
---@return dbquery.Run|nil
function Run.start(spec)
  local command = client.command(spec.resolved, spec.sql, spec.mode)
  if not command then
    return nil
  end

  local self = setmetatable({
    url = spec.url,
    resolved = spec.resolved,
    sql = spec.sql,
    mode = spec.mode,
    path = output.path(spec.srcName, command.extension),
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
    -- Detached, so the client leads its own process group. A client that
    -- shares nvim's group can be reached by a signal aimed at the group, and
    -- these clients are signalled to cancel them.
    detach = true,
  }, function(result)
    finish(self, result)
  end)

  table.insert(live, self)
  return self
end

--- Calls `subscriber` once this run has ended, on the main loop, with the
--- status already recorded. A run that has already ended calls it now.
---@param subscriber fun(run: dbquery.Run)
function Run:onFinish(subscriber)
  if self.status == "running" then
    table.insert(self.subscribers, subscriber)
  else
    subscriber(self)
  end
end

--- Asks for this query to stop, through the server wherever there is one to
--- ask and by interrupting the client where there is not.
---
--- A cancel is a request the client is still free to take its time over, so the
--- run stays running until it exits and reports the cancellation itself.
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
