--[[
Entry point for running queries from a sql buffer.

This module reads the sql, resolves the connection, and passes both to the
buffer's Source. ARCHITECTURE.md covers the flow from there.
]]

local command = require("db-query.command")
local config = require("db-query.config")
local connections = require("db-query.connections")
local output = require("db-query.output")
local selection = require("db-query.selection")
local Source = require("db-query.source")
local sql = require("db-query.sql")

local M = {}

---@class dbquery.ExecuteOptions : dbquery.Selection
---@field format dbquery.Format|nil Output format (default: config value).
---@field output string|true|nil Output path, true to prompt, nil to auto-generate.

--- Opens the connection picker, assigns the selection to `b:db`, and calls
--- the provided callback with the chosen url. A cancelled picker does nothing.
---
--- The connection is also stored in `g:db`, so subsequent sql buffers inherit
--- it without prompting. If the buffer is closed while the picker is open,
--- only `g:db` is set.
---@param chosen fun(url: string)|nil
function M.connect(chosen)
  local list, err = connections.list(config.values.connections)
  if err then
    return vim.notify("db-query: " .. err, vim.log.levels.ERROR)
  end
  if #list == 0 then
    return vim.notify("db-query: no connections configured", vim.log.levels.WARN)
  end

  local buf = vim.api.nvim_get_current_buf()
  vim.ui.select(list, {
    prompt = "Database",
    format_item = function(connection)
      return connection.name
    end,
  }, function(choice)
    if not choice then
      return
    end
    vim.g.db = choice.url
    if not vim.api.nvim_buf_is_loaded(buf) then
      return
    end

    vim.b[buf].db_name = choice.name
    vim.b[buf].db = choice.url

    -- vim-dadbod-completion caches b:db on first completion, so changing it
    -- requires re-fetching.
    pcall(vim.fn["vim_dadbod_completion#fetch"], buf)

    if chosen then
      chosen(choice.url)
    end
  end)
end

--- Returns the execution mode for `statement` given the requested `format`.
---
--- Text output works for any statement. Csv requires a single row-returning
--- statement; anything else falls back to text.
---@param statement string
---@param format dbquery.Format
---@return dbquery.Mode
local function modeFor(statement, format)
  if format == "csv" then
    if sql.canExport(statement) then
      return "export"
    end
  end
  return "script"
end

--- Resolves `url` through vim-dadbod, which expands `$VAR`, follows variable
--- references, and falls back through `w:db`, `t:db`, `b:db`, `g:db`, and
--- `$DATABASE_URL`.
---
--- Returns the url unchanged when dadbod is not installed. Returns nil when
--- `url` is nil or empty, signaling that the caller should prompt for a
--- connection.
---@param url string|nil
---@return string|nil
local function resolve(url)
  local ok, resolved = pcall(vim.fn["db#resolve"], url or "")
  if ok and resolved ~= "" then
    return resolved
  end
  return url
end

--- Runs the sql specified in `opts`.
---
---@param opts dbquery.ExecuteOptions|nil Defaults to the whole buffer as text.
function M.execute(opts)
  opts = opts or {}
  --- The sql and source lines are captured before any prompt opens, because
  --- opening a prompt exits visual mode and the user may move the cursor while
  --- a prompt is open.
  local statement, span = selection.text(opts)
  if statement == "" then
    return vim.notify("db-query: no query to run", vim.log.levels.WARN)
  end

  local mode = modeFor(statement, opts.format or config.values.format)
  local buf = vim.api.nvim_get_current_buf()

  ---@param outputPath string|nil
  local function run(outputPath)
    if not vim.api.nvim_buf_is_loaded(buf) then
      return
    end
    -- Store as absolute path so cwd changes don't affect the next prompt.
    if outputPath then
      vim.b[buf].db_last_output_path =
        output.destination(vim.api.nvim_buf_get_name(buf), outputPath)
    end

    ---@param url string|nil
    ---@param resolved string
    local function start(url, resolved)
      Source.of(buf):execute({
        url = url,
        resolved = resolved,
        sql = statement,
        mode = mode,
        span = span,
        outputPath = outputPath,
      })
    end

    local resolved = resolve(vim.b[buf].db)
    if resolved then
      return start(vim.b[buf].db, resolved)
    end

    M.connect(function(url)
      if not url then
        return
      end
      start(url, resolve(url))
    end)
  end

  if opts.output == true then
    vim.ui.input({
      prompt = "Output file",
      default = vim.b[buf].db_last_output_path
        or output.destination(vim.api.nvim_buf_get_name(buf)),
      completion = "file",
    }, function(value)
      value = value and vim.trim(value) or ""
      if value ~= "" then
        run(value)
      end
    end)
  else
    run(opts.output)
  end
end

--- Sets the output directory for this session. Files written there are not
--- auto-deleted. Numbering continues from existing files.
---
--- When `path` is nil, opens a prompt with the current directory as default.
--- An empty response resets to the configured `output_dir`. Cancelling the
--- prompt changes nothing.
---@param path string|nil
function M.outputDir(path)
  if path then
    return output.setDirectory(path)
  end

  vim.ui.input({
    prompt = "Output directory",
    default = output.directory(),
    completion = "dir",
  }, function(value)
    if value then
      output.setDirectory(vim.trim(value))
    end
  end)
end

--- Returns the spinner and elapsed time for a winbar or statusline, or an
--- empty string when no query is running in `buf`.
---
---     vim.o.winbar = "%{%v:lua.require'db-query'.status()%}"
---
---@param buf integer|nil Defaults to the current buffer.
---@return string
function M.status(buf)
  return Source.status(buf or vim.api.nvim_get_current_buf())
end

---@param opts dbquery.Config|nil
function M.setup(opts)
  config.set(opts)
  output.sweep()

  local group = vim.api.nvim_create_augroup("db-query", { clear = true })

  -- Inherit g:db so the connection is selected once per session, not per buffer.
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = { "sql", "mysql", "plsql" },
    callback = function(event)
      if vim.g.db and not vim.b[event.buf].db then
        vim.b[event.buf].db = vim.g.db
      end
    end,
  })

  command.setup()

  if config.values.parquet then
    require("db-query.parquet").setup(group)
  end
end

return M
