--[[
Running the query in a sql buffer.

The connection is `b:db`, a vim-dadbod url. That variable is the whole of what
this plugin shares with vim-dadbod and its completion source, and nothing here
reads or writes anything else of dadbod's.

This module is the way in: it reads the sql, finds the connection, and hands
both to the buffer's source. ARCHITECTURE.md draws what happens after that.
]]

local command = require("db-query.command")
local config = require("db-query.config")
local connections = require("db-query.connections")
local output = require("db-query.output")
local Source = require("db-query.source")
local sql = require("db-query.sql")

local M = {}

--- Which sql to run. Nothing named means the whole buffer.
---@class dbquery.Selection
---@field visual boolean|nil The visual selection, live or the one just ended.
---@field range [integer, integer]|nil First and last line, as a command's range gives them.
---@field statement boolean|nil The statement the cursor is in, of however many the buffer holds.

--- Which sql to run, and what becomes of what it prints.
---@class dbquery.ExecuteOptions : dbquery.Selection
---@field format dbquery.Format|nil What the client is asked for, defaulting to the configured format.
---@field output string|true|nil A path to write the output to, true to be asked for one, and nil for the file this plugin names.

--- The selection, and the lines it starts and ends on. Empty when nothing is
--- selected.
---
--- A `<cmd>` mapping leaves visual mode on and `'<` and `'>` still holding the
--- previous selection, so the live selection is read while it is there and the
--- marks only after it has ended, which is how a `-range` command arrives.
---@return string[] lines
---@return [integer, integer] span First and last line, as nvim counts them.
local function selection()
  local mode = vim.fn.mode()
  local from, to = vim.fn.getpos("v"), vim.fn.getpos(".")
  if not (mode == "v" or mode == "V" or mode == "\22") then
    mode = vim.fn.visualmode()
    if mode == "" then
      return {}, { 0, 0 }
    end
    from, to = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  end

  local lines = vim.fn.getregion(from, to, { type = mode })
  return lines, { math.min(from[2], to[2]) - 1, math.max(from[2], to[2]) - 1 }
end

--- The sql `opts` names, and the lines it was taken from: a command's range,
--- the visual selection, or the whole buffer.
---@param opts dbquery.Selection
---@return string sql
---@return [integer, integer] span First and last line, as nvim counts them.
local function sqlText(opts)
  local lines, span
  if opts.range then
    lines = vim.api.nvim_buf_get_lines(0, opts.range[1] - 1, opts.range[2], false)
    span = { opts.range[1] - 1, opts.range[2] - 1 }
  elseif opts.visual then
    lines, span = selection()
  elseif opts.statement then
    local buffer = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local found = sql.statementAt(buffer, vim.api.nvim_win_get_cursor(0)[1] - 1)
    span = found or { 0, 0 }
    lines = found and vim.list_slice(buffer, found[1] + 1, found[2] + 1) or {}
  else
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    span = { 0, #lines - 1 }
  end
  return vim.trim(table.concat(lines, "\n")), span
end

--- Asks which database this buffer speaks to and assigns it, then calls
--- `chosen` with the url. A cancelled choice calls nothing.
---
--- The connection is remembered in `g:db` as well, which is what gives the next
--- sql buffer a connection without being asked again. When the buffer this was
--- opened for has been closed in the meantime, remembering it is all a choice
--- can do, and `chosen` is not called.
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

    -- vim-dadbod-completion reads b:db once per buffer and keeps what it found,
    -- so a buffer that has completed already goes on completing against the
    -- database it was pointed at before this.
    pcall(vim.fn["vim_dadbod_completion#fetch"], buf)

    if chosen then
      chosen(choice.url)
    end
  end)
end

--- How to run `statement` to get `format` out of it.
---
--- Text is what the client prints for itself, and every statement can be run
--- that way. Csv is a rendering of one result set, so it is asked for only when
--- the sql is the single row-returning statement that can fill one, and
--- anything else falls back to text rather than failing.
---@param statement string
---@param format dbquery.Format
---@return dbquery.Mode
local function modeFor(statement, format)
  if format == "csv" then
    return sql.mode(statement)
  end
  return "script"
end

--- `url` as vim-dadbod would take it, which expands `$VAR`, follows a variable
--- name, and falls back to `w:db`, `t:db`, `b:db`, `g:db` and `$DATABASE_URL`
--- when `url` is nil. The client is then given the url completion connects
--- with.
---
--- Anything dadbod cannot answer for, including not being installed, leaves the
--- url as it came in, and running it is where that is found out. Nil in is nil
--- out, which is how the caller knows to ask for a connection. Dadbod answers
--- a buffer with no connection anywhere in that chain with an empty url, which
--- is the same answer.
---@param url string|nil
---@return string|nil
local function resolve(url)
  local ok, resolved = pcall(vim.fn["db#resolve"], url or "")
  if ok and resolved ~= "" then
    return resolved
  end
  return url
end

--- Calls `use` with the path and base name the output is to be written to, and
--- with nil for the one this plugin makes up.
---
--- `true` asks for one, offering what this buffer was last given, so running
--- the same export again is a matter of accepting what is already in the
--- prompt. A cancelled prompt runs nothing.
---@param buf integer
---@param wanted string|true|nil
---@param use fun(outputPath: string|nil)
local function chooseOutput(buf, wanted, use)
  if wanted ~= true then
    return use(wanted)
  end

  vim.ui.input({
    prompt = "Output file",
    default = vim.b[buf].db_last_output_path
      or output.destination(vim.api.nvim_buf_get_name(buf)),
    completion = "file",
  }, function(value)
    value = value and vim.trim(value) or ""
    if value ~= "" then
      use(value)
    end
  end)
end

--- Runs the sql `opts` names, asking where the output goes when `output` is
--- true and for a connection when the buffer has none.
---
--- The sql and the place it was run from are read before either is asked for,
--- because choosing ends visual mode and takes the selection with it, and gives
--- the user time to move somewhere else before the query starts.
---@param opts dbquery.ExecuteOptions|nil Defaults to the whole buffer as text.
function M.execute(opts)
  opts = opts or {}
  local statement, span = sqlText(opts)
  if statement == "" then
    return vim.notify("db-query: no query to run", vim.log.levels.WARN)
  end

  local mode = modeFor(statement, opts.format or config.values.format)
  local buf = vim.api.nvim_get_current_buf()

  ---@param outputPath string|nil
  local function run(outputPath)
    -- The prompt gives the user time to close the buffer the sql came from.
    if not vim.api.nvim_buf_is_loaded(buf) then
      return
    end
    -- Remembered as the full path, so a working directory change does not move
    -- what the prompt offers next time.
    if outputPath then
      outputPath = output.destination(vim.api.nvim_buf_get_name(buf), outputPath)
      vim.b[buf].db_last_output_path = outputPath
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
      start(url, resolve(url))
    end)
  end

  chooseOutput(buf, opts.output, run)
end

--- The spinner and the clock for a winbar or a statusline, empty unless `buf`
--- is running a query. It turns while the query runs, so it is drawn where a
--- long buffer would have scrolled the indicator out of sight:
---
---     vim.o.winbar = "%{%v:lua.require'db-query'.status()%}"
---
---@param buf integer|nil Defaults to the buffer being drawn.
---@return string
function M.status(buf)
  return Source.status(buf or vim.api.nvim_get_current_buf())
end

---@param opts dbquery.Config|nil
function M.setup(opts)
  config.set(opts)
  output.sweep()

  -- Cleared, so calling setup twice leaves one of each rather than two.
  local group = vim.api.nvim_create_augroup("db-query", { clear = true })

  -- A new sql buffer speaks to whatever was last chosen, so the connection is
  -- picked once per session rather than once per buffer.
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
