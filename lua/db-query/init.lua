--[[
Sets up the plugin and carries out each request a user makes of a sql buffer,
such as connecting it, running a query, or showing the output.
]]

local catalog = require("db-query.catalog")
local client = require("db-query.client")
local command = require("db-query.command")
local config = require("db-query.config")
local connection = require("db-query.connection")
local dadbod = require("db-query.connection.dadbod")
local files = require("db-query.query.files")
local mainloop = require("db-query.mainloop")
local Progress = require("db-query.query.progress")
local selection = require("db-query.query.selection")
local Source = require("db-query.query.source")

---@class dbquery.Api
local M = {}

local FILETYPES = { "sql", "mysql", "plsql" }

---@class dbquery.ExecuteOptions : dbquery.Selection
---@field format dbquery.Format|nil Output format (default: config value).
---@field output string|true|nil Output path, true to prompt, nil to auto-generate.

--- Opens the connection picker for `buf` and calls `chosen` once the choice
--- has connected.
---@param buf integer|nil Buffer to connect (default: the current one).
---@param chosen fun(connection: dbquery.Connection)|nil
function M.connect(buf, chosen)
  mainloop.capture(function()
    return buf or vim.api.nvim_get_current_buf()
  end, function(current)
    connection.pick(current, chosen)
  end)
end

--- Runs the sql that `opts` selects.
---@param opts dbquery.ExecuteOptions|nil Defaults to the whole buffer as text.
function M.execute(opts)
  opts = opts or {}
  -- The lines are captured before any prompt opens, because opening a prompt
  -- exits visual mode, and the cursor may move while a prompt is open.
  mainloop.capture(function()
    return selection.capture(opts), vim.api.nvim_get_current_buf()
  end, function(capture, buf)
    if selection.blank(capture) then
      return vim.notify("db-query: no query to run", vim.log.levels.WARN)
    end
    local format = opts.format or config.values.format

    ---@param outputPath string|nil
    ---@param url string|nil
    ---@param connectionName string|nil
    ---@param resolved string
    local function start(outputPath, url, connectionName, resolved)
      local dbClient = client.known(resolved)
      if not dbClient then
        return
      end
      local statement, span = selection.sql(capture, dbClient.dialect)
      if statement == "" then
        return vim.notify("db-query: no query to run", vim.log.levels.WARN)
      end
      -- Stored as an absolute path, so a change of cwd doesn't move the next
      -- prompt's default.
      if outputPath then
        vim.b[buf].db_last_output_path = files.destination(vim.api.nvim_buf_get_name(buf), outputPath)
      end
      Source.of(buf):execute({
        buf = buf,
        url = url,
        connectionName = connectionName,
        resolved = resolved,
        client = dbClient,
        sql = statement,
        bufName = vim.api.nvim_buf_get_name(buf),
        format = format,
        span = span,
        outputPath = outputPath,
      })
    end

    ---@param outputPath string|nil
    local function connectAndStart(outputPath)
      if not vim.api.nvim_buf_is_loaded(buf) then
        return
      end
      -- `b:db` still holds the connection the test may replace.
      local testing = connection.testing(buf)
      if testing then
        return vim.notify(
          "db-query: still testing " .. testing .. ", run the query again once it answers",
          vim.log.levels.WARN
        )
      end

      local url = vim.b[buf].db
      local resolved = dadbod.resolve(url)
      if resolved then
        return start(outputPath, url, vim.b[buf].db_name, resolved)
      end
      connection.pick(buf, function(chosen)
        local resolvedChoice = dadbod.resolve(chosen.url)
        if resolvedChoice then
          start(outputPath, chosen.url, chosen.name, resolvedChoice)
        end
      end)
    end

    if opts.output == true then
      vim.ui.input({
        prompt = "Output file",
        default = vim.b[buf].db_last_output_path or files.destination(vim.api.nvim_buf_get_name(buf)),
        completion = "file",
      }, mainloop.wrap(function(answer)
        answer = answer and vim.trim(answer) or ""
        if answer ~= "" then
          connectAndStart(answer)
        end
      end))
    else
      connectAndStart(opts.output)
    end
  end)
end

--- Calls `act` with the resolved url of `buf`'s connection, or warns that it
--- has none.
---@param buf integer|nil Defaults to the current buffer.
---@param act fun(resolved: string)
local function withConnection(buf, act)
  mainloop.capture(function()
    return dadbod.resolve(vim.b[buf or vim.api.nvim_get_current_buf()].db)
  end, function(resolved)
    if not resolved then
      return vim.notify("db-query: this buffer has no connection", vim.log.levels.WARN)
    end
    act(resolved)
  end)
end

--- Reads the catalog of `buf`'s connection again, in the background.
---@param buf integer|nil Defaults to the current buffer.
function M.refreshCatalog(buf)
  withConnection(buf, catalog.refresh)
end

--- Stops the read of the catalog of `buf`'s connection.
---@param buf integer|nil Defaults to the current buffer.
function M.cancelCatalog(buf)
  withConnection(buf, catalog.cancel)
end

--- Sets the output directory for this session. Files written there are not
--- auto-deleted. Numbering continues from existing files.
---
--- When `path` is nil, opens a prompt with the current directory as default.
--- An empty response resets to the configured `output_dir`. Cancelling the
--- prompt changes nothing.
---@param path string|nil
function M.outputDir(path)
  mainloop.run(function()
    if path then
      return files.setDirectory(path)
    end

    vim.ui.input({
      prompt = "Output directory",
      default = files.directory(),
      completion = "dir",
    }, mainloop.wrap(function(answer)
      if answer then
        files.setDirectory(vim.trim(answer))
      end
    end))
  end)
end

--- Shows the log or the last query's result in the output window, reopening
--- that window if it was closed, closes the output windows, or runs the last
--- query again. Works from the sql buffer and from the output window alike.
---@param action dbquery.OutputAction
function M.output(action)
  mainloop.capture(vim.api.nvim_get_current_buf, function(buf)
    local source = Source.owning(buf)
    if not source then
      return vim.notify("db-query: no query output for this buffer", vim.log.levels.WARN)
    end
    source:output(action)
  end)
end

--- Returns the spinner, what is running, and elapsed time for a winbar or
--- statusline, or an empty string when nothing is running for `buf`. A query
--- or connection test in `buf` shows ahead of a read of its database's catalog.
--- Call it only from nvim's main loop, which a statusline always is.
---
---     vim.o.winbar = "%{%v:lua.require'db-query'.statusline()%}"
---
---@param buf integer|nil Defaults to the current buffer.
---@return string
function M.statusline(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local running = Source.statusline(buf)
  if running ~= "" then
    return running
  end
  local seconds = catalog.reading(function()
    local url = vim.b[buf].db
    return type(url) == "string" and dadbod.resolve(url) or nil
  end)
  if not seconds then
    return ""
  end
  return Progress.format(vim.trim("reading catalog " .. (vim.b[buf].db_name or "")), seconds)
end

---@class dbquery.DescribeOptions : dbquery.CatalogName
---@field url string A connection url, as `b:db` holds it.

--- Returns the lines of markdown that hover shows for a table, view, or
--- column, or nil and why there are none:
---
--- - `"no connection url"`
--- - `"no client known for <scheme>"`
--- - `"reading"`, while the first read of the database's catalog runs. The
---   first call for a database starts that read.
--- - `"no catalog"`, when that read failed. `:DBRefreshCatalog` reads it again.
--- - `"not found"`, when the catalog holds nothing by that name.
---
--- Call it only from nvim's main loop.
---
---     local lines = require("db-query").describe({ url = url, relation = { "public", "orders" } })
---     if lines then
---       vim.lsp.util.open_floating_preview(lines, "markdown")
---     end
---
---@param opts dbquery.DescribeOptions
---@return string[]|nil lines
---@return string|nil err
function M.describe(opts)
  local resolved = dadbod.resolve(opts.url)
  if not resolved then
    return nil, "no connection url"
  end
  local dbClient = client.of(resolved)
  if not dbClient then
    return nil, "no client known for " .. require("db-query.client.url").scheme(resolved)
  end
  local dbCatalog = catalog.get(resolved)
  if not dbCatalog then
    local reading = catalog.reading(function()
      return resolved
    end)
    return nil, reading and "reading" or "no catalog"
  end
  local named = require("db-query.lsp.target").named(dbCatalog, dbClient.dialect, opts)
  if not named then
    return nil, "not found"
  end
  return require("db-query.lsp.hover").markdown(dbClient.dialect, named)
end

---@class dbquery.ReadOptions
---@field url string A connection url, as `b:db` holds it.
---@field statement string

--- Runs `opts.statement` read-only on the database `opts.url` names, and calls
--- `done` once, on a later tick of the main loop, with what it printed,
--- unaligned and without a header, or with why it failed. The client is killed
--- after the `catalog.timeout` setting.
---
---     require("db-query").read({ url = url, statement = "select 1" }, function(output, err) end)
---
---@param opts dbquery.ReadOptions
---@param done fun(output: string|nil, err: string|nil)
function M.read(opts, done)
  done = vim.schedule_wrap(done)
  local resolved = dadbod.resolve(opts.url)
  if not resolved then
    return done(nil, "no connection url")
  end
  local dbClient = client.of(resolved)
  if not dbClient then
    return done(nil, "no client known for " .. require("db-query.client.url").scheme(resolved))
  end
  client.read({
    client = dbClient,
    connection = resolved,
    statement = opts.statement,
    timeout = config.values.catalog.timeout,
    readonly = true,
  }, done)
end

--- Deprecated name of `statusline`.
---@deprecated Use `statusline`.
---@param buf integer|nil
---@return string
function M.status(buf)
  return M.statusline(buf)
end

---@param opts dbquery.Config|nil
function M.setup(opts)
  mainloop.run(function()
    config.set(opts)
    files.sweep()

    local group = vim.api.nvim_create_augroup("db-query", { clear = true })

    -- The language server is attached here rather than through `vim.lsp.enable`,
    -- which skips a buffer with a `buftype`, and the scratch buffers other
    -- plugins open for sql are `nofile`.
    vim.api.nvim_create_autocmd("FileType", {
      group = group,
      pattern = FILETYPES,
      callback = function(event)
        connection.opened(event.buf)
        if config.values.lsp then
          require("db-query.lsp").attach(event.buf)
        end
      end,
    })
    if config.values.lsp then
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.tbl_contains(FILETYPES, vim.bo[buf].filetype) then
          require("db-query.lsp").attach(buf)
        end
      end
    end

    vim.api.nvim_create_autocmd("BufWritePost", {
      group = group,
      callback = function(event)
        if vim.tbl_contains(FILETYPES, vim.bo[event.buf].filetype) then
          connection.follow(event.buf)
        end
      end,
    })

    command.setup(M)

    if config.values.parquet then
      require("db-query.parquet").setup(group)
    end
  end)
end

return M
