--[[
A running query, its files, and the process writing them.

The client writes directly to files and nvim reads those files, which keeps
large result sets out of lua memory. Everything the client prints goes to the
log, and rows go to a separate results file, which only exists when the
statement returns any.
]]

local client = require("db-query.client")
local files = require("db-query.query.files")
local Process = require("db-query.query.process")
local sql = require("db-query.sql")

---@class dbquery.Run
---@field ctx dbquery.Context What was asked for.
---@field log dbquery.Log The log every run of this buffer appends to.
---@field path string|nil Results file, when the statement returns rows.
---@field staged string|nil Path the client wrote rows to, moved onto `path`.
---@field process dbquery.Process
local Run = {}
Run.__index = Run

---@param argument string
---@return string
local function quoted(argument)
  return "'" .. argument:gsub("'", "'\\''") .. "'"
end

--- Wraps `argv` in a shell that files the client's output. Uses `exec` so
--- signals reach the client directly.
---
--- A client that writes its own rows leaves both streams for the log. One that
--- cannot names a `rowsPath` for stdout, so only stderr reaches the log.
---@param argv string[]
---@param logPath string
---@param rowsPath string|nil
---@return string[]
local function shellArgv(argv, logPath, rowsPath)
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

  if rowsPath then
    return { "sh", "-c", line .. " >" .. quoted(rowsPath) .. " 2>>" .. quoted(logPath) }
  end
  return { "sh", "-c", line .. " >>" .. quoted(logPath) .. " 2>&1" }
end

--- What one query was asked to do, fixed when the user ran it.
---@class dbquery.Context
---@field buf integer Sql buffer the query came from.
---@field url string|nil Connection as written, for b:db.
---@field connectionName string|nil Connection's chosen name, for b:db_name.
---@field resolved string Resolved connection (may include password).
---@field dialect dbquery.Dialect The rules the connection's client reads sql by.
---@field sql string
---@field bufName string Sql buffer's file name, for naming output files.
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
  local rowKind = sql.rowKind(ctx.dialect, ctx.sql)
  local extension = client.target(ctx.resolved, rowKind, ctx.format)

  local path = nil
  if extension then
    path = files.path(ctx.bufName, extension, ctx.outputPath)
    if not path then
      return nil
    end
  elseif ctx.outputPath then
    vim.notify(
      "db-query: this query returns no rows, so nothing is written to " .. ctx.outputPath,
      vim.log.levels.WARN
    )
  end

  local stagingPath = extension and files.staging(extension) or nil
  local command = client.command({
    connection = ctx.resolved,
    statement = ctx.sql,
    format = ctx.format,
    kind = rowKind,
    path = path,
    staging = stagingPath,
    readonly = false,
  })
  if not command then
    return nil
  end

  ---@type dbquery.Run
  local self = setmetatable({
    ctx = ctx,
    log = log,
    path = path,
    staged = command.staged and stagingPath or nil,
  }, Run)
  log:begin(self)

  local process, err = Process.start({
    argv = shellArgv(command.argv, log.path, command.stdout),
    command = command,
    askServer = function()
      return command.sessionFile ~= nil and client.cancel(ctx.resolved, command.sessionFile)
    end,
  })
  if not process then
    local reason = tostring(err)
    log:close(self, reason)
    vim.notify("db-query: " .. reason, vim.log.levels.ERROR)
    return nil
  end
  self.process = process

  -- The rows move before the log is closed, so nothing that goes wrong writing
  -- the log can lose them. A run that did not finish leaves the results file in
  -- place, because two runs pointed at the same `-o` path share it.
  process:onFinish(function()
    if self.staged then
      if process.status == "ok" and self.path then
        if not vim.uv.fs_rename(self.staged, self.path) and vim.uv.fs_copyfile(self.staged, self.path) then
          vim.uv.fs_unlink(self.staged)
        end
      end
      os.remove(self.staged)
    end
    log:close(self)
  end)
  return self
end

return Run
