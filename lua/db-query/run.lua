--[[
A running query.

The client writes directly to files and nvim reads those files. This keeps
large result sets out of lua memory.

Everything the client prints goes to the log, which every run of a source
buffer appends to. Rows go to a separate file, which only exists when the
statement returns any.

A Run holds its files and the process writing them, along with the request it
came from as `run.ctx`, which is where the indicator and the pane read what
they need.
]]

local client = require("db-query.client")
local output = require("db-query.output")
local Process = require("db-query.process")
local sql = require("db-query.sql")

---@class dbquery.Run
---@field id integer Distinguishes runs sharing a log.
---@field ctx dbquery.Context What was asked for.
---@field log string Log file, appended to by every run of this buffer.
---@field path string|nil Results file, when the statement returns rows.
---@field staged string|nil Path the client wrote rows to, moved onto `path`.
---@field process dbquery.Process
local Run = {}
Run.__index = Run

--- Counts runs, so each one is named in the log it shares with the others.
local started = 0

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

--- Writes the footer and puts the rows where they were asked for.
---
--- A query that did not finish leaves its results file behind rather than
--- deleting it, because two runs pointed at the same `-o` path share it and
--- the one that failed must not take the other's output with it.
---@param self dbquery.Run
local function finish(self)
  local status = self.process.status
  local label = status == "ok" and "finished" or status
  append(self.log, string.format("\n[%d %s in %.3fs]\n", self.id, label, self.process:elapsed()))

  if self.staged then
    if status == "ok" and self.path then
      move(self.staged, self.path)
    end
    os.remove(self.staged)
  end
end

--- What one query was asked to do, fixed when the user ran it. Every component
--- of a run reads it from `run.ctx`.
---@class dbquery.Context
---@field buf integer Sql buffer the query came from.
---@field url string|nil Connection as written, for b:db.
---@field name string|nil Connection's chosen name, for b:db_name.
---@field resolved string Resolved connection (may include password).
---@field dialect dbquery.Dialect The rules the connection's client reads sql by.
---@field sql string
---@field srcName string Sql buffer's file name, for naming output files.
---@field format dbquery.Format
---@field span [integer, integer] First and last line the sql came from.
---@field outputPath string|nil User-specified output path.

--- Starts the client process. Returns nil when the log cannot be created,
--- when the user declines to write over the results file, when no client is
--- known for the url, or when the process cannot start.
---@param ctx dbquery.Context
---@return dbquery.Run|nil
function Run.start(ctx)
  local log = output.log(ctx.srcName)
  if not log then
    return nil
  end

  local kind = sql.rowKind(ctx.dialect, ctx.sql)
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
  }, Run)
  announce(self)

  local process, err = Process.start({
    argv = writingTo(command.argv, log, command.stdout),
    command = command,
    askServer = function()
      return command.sessionFile ~= nil and client.cancel(ctx.resolved, command.sessionFile)
    end,
  })
  if not process then
    vim.notify("db-query: " .. tostring(err), vim.log.levels.ERROR)
    return nil
  end
  self.process = process
  process:onFinish(function()
    finish(self)
  end)
  return self
end

return Run
