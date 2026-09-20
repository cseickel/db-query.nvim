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
---@field ctx dbquery.Context What was asked for.
---@field log dbquery.LogEntry This run's place in the log every run of this buffer appends to.
---@field path string|nil Results file, when the statement returns rows.
---@field staged string|nil Path the client wrote rows to, moved onto `path`.
---@field process dbquery.Process
local Run = {}
Run.__index = Run

--- How each way a run can end is said in the log.
---@type table<dbquery.Status, dbquery.LogMessage>
local COMPLETION = {
  ok = "success_complete",
  failed = "error_complete",
  cancelled = "cancel_complete",
}

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
---@param logPath string
---@param rows string|nil
---@return string[]
local function writingTo(argv, logPath, rows)
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
    return { "sh", "-c", line .. " >" .. quoted(rows) .. " 2>>" .. quoted(logPath) }
  end
  return { "sh", "-c", line .. " >>" .. quoted(logPath) .. " 2>&1" }
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

--- Puts the rows where they were asked for, then says in the log how the run
--- ended. The rows move first, so nothing that goes wrong writing the log can
--- lose them.
---
--- A query that did not finish leaves its results file behind rather than
--- deleting it, because two runs pointed at the same `-o` path share it and
--- the one that failed must not take the other's output with it.
---@param self dbquery.Run
local function finish(self)
  local status = self.process.status
  if self.staged then
    if status == "ok" and self.path then
      move(self.staged, self.path)
    end
    os.remove(self.staged)
  end

  self.log:append(COMPLETION[status])
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

--- Starts the client process. Returns nil when the user declines to write over
--- the results file, when no client is known for the url, or when the process
--- cannot start.
---@param ctx dbquery.Context
---@param log dbquery.Log The log of the buffer the query came from.
---@return dbquery.Run|nil
function Run.start(ctx, log)
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
    readonly = false,
  })
  if not command then
    return nil
  end

  local entry = log:entry(ctx, path)
  local self = setmetatable({
    ctx = ctx,
    log = entry,
    path = path,
    staged = command.staged and staging or nil,
  }, Run)
  entry:append("query", ctx.sql)

  local process, err = Process.start({
    argv = writingTo(command.argv, entry.path, command.stdout),
    command = command,
    askServer = function()
      return command.sessionFile ~= nil and client.cancel(ctx.resolved, command.sessionFile)
    end,
  })
  if not process then
    local reason = tostring(err)
    entry:append("output", reason)
    entry:append("error_complete")
    vim.notify("db-query: " .. reason, vim.log.levels.ERROR)
    return nil
  end
  self.process = process
  process:onFinish(function()
    finish(self)
  end)
  return self
end

return Run
