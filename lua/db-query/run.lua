--[[
A running query.

The client writes directly to files and nvim reads those files. This keeps
large result sets out of lua memory.

Everything the client prints goes to the log, which every run of a source
buffer appends to. Rows go to a separate file, which only exists when the
statement returns any.

A Run holds the process, its files, and its status, along with the request it
came from as `run.ctx`, which is where the indicator and the pane read what
they need. Interested parties subscribe via onFinish().
]]

local client = require("db-query.client")
local output = require("db-query.output")
local sql = require("db-query.sql")
local url = require("db-query.url")

---@alias dbquery.Status "running"|"ok"|"failed"|"cancelled"

---@class dbquery.Run
---@field id integer Distinguishes runs sharing a log.
---@field ctx dbquery.Context What was asked for.
---@field log string Log file, appended to by every run of this buffer.
---@field path string|nil Results file, when the statement returns rows.
---@field staged string|nil Path the client wrote rows to, moved onto `path`.
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

--- Counts runs, so each one is named in the log it shares with the others.
local started = 0

local GROUP = vim.api.nvim_create_augroup("db-query.run", { clear = true })

-- Kill running clients on exit, because detached processes don't die with nvim.
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

--- Wraps `argv` in a shell that files the client's output. Uses `exec` so
--- signals reach the client directly.
---
--- A client that writes its own rows leaves both streams for the log. One that
--- cannot names a `rows` file for stdout, so only stderr reaches the log.
---@param argv string[]
---@param log string
---@param rows string|nil
---@return string[]
local function writingTo(argv, log, rows)
  local words = {}
  for _, argument in ipairs(argv) do
    table.insert(words, quoted(argument))
  end
  -- Line-buffer output so a running query shows progress.
  local line = table.concat(words, " ")
  if vim.fn.executable("stdbuf") == 1 then
    line = "stdbuf -oL " .. line
  end
  line = "exec " .. line

  if rows then
    return { "sh", "-c", line .. " >" .. quoted(rows) .. " 2>>" .. quoted(log) }
  end
  return { "sh", "-c", line .. " >>" .. quoted(log) .. " 2>&1" }
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

--- A client killed by a signal exits with code 0, so the signal decides too.
---@param self dbquery.Run
---@param result vim.SystemCompleted
---@return dbquery.Status
local function outcome(self, result)
  if result.code == 0 and result.signal == 0 then
    return "ok"
  end
  return self.asked and "cancelled" or "failed"
end

---@param path string
---@param text string
local function append(path, text)
  local file = io.open(path, "a")
  if file then
    file:write(text)
    file:close()
  end
end

--- Moves `from` onto `to`, copying when the two are on different filesystems.
---@param from string
---@param to string
local function move(from, to)
  if vim.uv.fs_rename(from, to) then
    return
  end
  if vim.uv.fs_copyfile(from, to) then
    vim.uv.fs_unlink(from)
  end
end

--- Opens the log with what is about to run, so the pane has something to show
--- before the client prints anything.
---
--- The id repeats in the footer, because a cancelled query goes on writing
--- while its replacement is already appending to the same log.
---@param self dbquery.Run
local function announce(self)
  local lines = { "", string.format("-- [%d] %s", self.id, os.date("%Y-%m-%d %H:%M:%S")) }
  if self.path then
    table.insert(lines, "-- rows -> " .. self.path)
  end
  vim.list_extend(lines, { self.ctx.sql, "" })
  append(self.log, table.concat(lines, "\n"))
end

--- Handles process exit: writes the footer, puts the rows where they were
--- asked for, updates status, notifies subscribers.
---
--- A query that did not finish leaves its results file behind rather than
--- deleting it, because two runs pointed at the same `-o` path share it and
--- the one that failed must not take the other's output with it.
---@param self dbquery.Run
---@param result vim.SystemCompleted
local function finish(self, result)
  local status = outcome(self, result)
  append(
    self.log,
    string.format(
      "\n[%d %s in %.3fs]\n",
      self.id,
      status == "ok" and "finished" or status,
      self:elapsed()
    )
  )

  if self.staged then
    if status == "ok" and self.path then
      move(self.staged, self.path)
    end
    os.remove(self.staged)
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

--- What one query was asked to do, fixed when the user ran it. Every component
--- of a run reads it from `run.ctx`.
---@class dbquery.Context
---@field buf integer Sql buffer the query came from.
---@field url string|nil Connection as written, for b:db.
---@field name string|nil Connection's chosen name, for b:db_name.
---@field resolved string Resolved connection (may include password).
---@field sql string
---@field srcName string Sql buffer's file name, for naming output files.
---@field format dbquery.Format
---@field span [integer, integer] First and last line the sql came from.
---@field outputPath string|nil User-specified output path.

--- Starts the client process. Returns nil on invalid url or cancelled output.
---@param ctx dbquery.Context
---@return dbquery.Run|nil
function Run.start(ctx)
  local log = output.log(ctx.srcName)
  if not log then
    return nil
  end

  local kind = sql.rowKind(ctx.sql, url.scheme(ctx.resolved))
  local extension = client.target(ctx.resolved, kind, ctx.format)

  local path = nil
  if extension then
    path = output.path(ctx.srcName, extension, ctx.outputPath)
    if not path then
      return nil
    end
  elseif ctx.outputPath then
    vim.notify(
      "db-query: this query returns no rows, so nothing is written to " .. ctx.outputPath,
      vim.log.levels.WARN
    )
  end

  local staging = extension and output.staging(extension) or nil
  local command = client.command({
    connection = ctx.resolved,
    statement = ctx.sql,
    format = ctx.format,
    kind = kind,
    path = path,
    staging = staging,
  })
  if not command then
    return nil
  end

  started = started + 1
  local self = setmetatable({
    id = started,
    ctx = ctx,
    log = log,
    path = path,
    staged = command.staged and staging or nil,
    status = "running",
    started = vim.uv.hrtime(),
    sessionFile = command.sessionFile,
    asked = false,
    subscribers = {},
  }, Run)
  announce(self)

  self.job = vim.system(writingTo(command.argv, self.log, command.stdout), {
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
  if not (self.sessionFile and client.cancel(self.ctx.resolved, self.sessionFile)) then
    self.job:kill("sigint")
  end
end

return Run
