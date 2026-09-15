--[[
Entry point for running queries from a sql buffer.

This module captures the sql, resolves the connection, reads the sql by the
connection's dialect, and passes it all to the buffer's Source. ARCHITECTURE.md
covers the flow from there.
]]

local catalog = require("db-query.catalog")
local client = require("db-query.client")
local command = require("db-query.command")
local config = require("db-query.config")
local connect = require("db-query.connect")
local dadbod = require("db-query.dadbod")
local output = require("db-query.output")
local selection = require("db-query.selection")
local Source = require("db-query.source")

local M = {}

local FILETYPES = { "sql", "mysql", "plsql" }

---@class dbquery.ExecuteOptions : dbquery.Selection
---@field format dbquery.Format|nil Output format (default: config value).
---@field output string|true|nil Output path, true to prompt, nil to auto-generate.

--- Opens the connection picker for `buf` and calls `chosen` once the choice
--- has connected. See `connect.pick`.
---@param buf integer|nil Buffer to connect (default: the current one).
---@param chosen fun(connection: dbquery.Connection)|nil
function M.connect(buf, chosen)
  connect.pick(buf, chosen)
end

--- Runs the sql specified in `opts`.
---
---@param opts dbquery.ExecuteOptions|nil Defaults to the whole buffer as text.
function M.execute(opts)
  opts = opts or {}
  -- The lines are captured before any prompt opens, because opening a prompt
  -- exits visual mode, and the cursor may move while a prompt is open.
  local capture = selection.capture(opts)
  if selection.blank(capture) then
    return vim.notify("db-query: no query to run", vim.log.levels.WARN)
  end

  local format = opts.format or config.values.format
  local buf = vim.api.nvim_get_current_buf()

  ---@param outputPath string|nil
  local function run(outputPath)
    if not vim.api.nvim_buf_is_loaded(buf) then
      return
    end

    ---@param url string|nil
    ---@param name string|nil
    ---@param resolved string
    local function start(url, name, resolved)
      local dialect = client.dialect(resolved)
      if not dialect then
        return
      end
      local statement, span = selection.text(capture, dialect)
      if statement == "" then
        return vim.notify("db-query: no query to run", vim.log.levels.WARN)
      end
      -- Store as absolute path so cwd changes don't affect the next prompt.
      if outputPath then
        vim.b[buf].db_last_output_path =
          output.destination(vim.api.nvim_buf_get_name(buf), outputPath)
      end
      Source.of(buf):execute({
        buf = buf,
        url = url,
        name = name,
        resolved = resolved,
        dialect = dialect,
        sql = statement,
        srcName = vim.api.nvim_buf_get_name(buf),
        format = format,
        span = span,
        outputPath = outputPath,
      })
    end

    local testing = connect.testing(buf)
    if testing then
      return vim.notify(
        "db-query: still testing " .. testing .. ", run the query again once it answers",
        vim.log.levels.WARN
      )
    end

    local written = vim.b[buf].db
    local resolved = dadbod.resolve(written)
    if resolved then
      return start(written, vim.b[buf].db_name, resolved)
    end

    connect.pick(buf, function(connection)
      local chosen = dadbod.resolve(connection.url)
      if chosen then
        start(connection.url, connection.name, chosen)
      end
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

--- Reads the catalog of `buf`'s connection again, in the background.
---@param buf integer|nil Defaults to the current buffer.
function M.refreshCatalog(buf)
  local resolved = dadbod.resolve(vim.b[buf or vim.api.nvim_get_current_buf()].db)
  if not resolved then
    return vim.notify("db-query: this buffer has no connection", vim.log.levels.WARN)
  end
  catalog.refresh(resolved)
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

--- Shows the log or the last query's result in the output window, reopening
--- that window if it was closed. Works from the sql buffer and from the output
--- window alike.
---@param view dbquery.OutputView
function M.output(view)
  local source = Source.owning(vim.api.nvim_get_current_buf())
  if not source then
    return vim.notify("db-query: no query output for this buffer", vim.log.levels.WARN)
  end
  source:output(view)
end

--- Returns the spinner, what is running, and elapsed time for a winbar or
--- statusline, or an empty string when no query or connection test is running
--- in `buf`.
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

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = FILETYPES,
    callback = function(event)
      connect.opened(event.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(event)
      if vim.tbl_contains(FILETYPES, vim.bo[event.buf].filetype) then
        connect.follow(event.buf)
      end
    end,
  })

  command.setup()

  if config.values.parquet then
    require("db-query.parquet").setup(group)
  end
end

return M
