--[[
Running the query in a sql buffer.

The connection is `b:db`, a vim-dadbod url. That variable is the whole of what
this plugin shares with vim-dadbod and its completion source, and nothing here
reads or writes anything else of dadbod's.

A query runs through the database's own client, which writes what it prints
straight to a file. The output never passes through lua, so a result set large
enough to exhaust nvim's memory cannot.
]]

local connections = require("db-query.connections")
local pane = require("db-query.pane")
local query = require("db-query.query")

local M = {}

---@alias dbquery.Format "text"|"csv"

--- Which sql to run. Nothing named means the whole buffer.
---@class dbquery.Source
---@field visual boolean|nil The visual selection, live or the one just ended.
---@field range [integer, integer]|nil First and last line, as a command's range gives them.

---@class dbquery.Config
---@field connections? dbquery.Connection[]|fun(): dbquery.Connection[]|nil Where the chooser gets its list, replacing the built-in sources.
---@field parquet boolean Whether opening a `*.parquet` opens a duckdb query against it.
---@field cancel string The key that stops a running query, bound only while one runs.
---@field format dbquery.Format "text" is native cli output, "csv" export to csv.

---@type dbquery.Config
local config = {
  parquet = false,
  cancel = "<C-c>",
  format = "text",
}

--- The selected lines, empty when nothing is selected. A `<cmd>` mapping leaves
--- visual mode on and `'<` and `'>` still holding the previous selection, so
--- the live selection is read while it is there and the marks only after it has
--- ended, which is how a `-range` command arrives.
---@return string[]
local function selectedLines()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    return vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
  end

  local kind = vim.fn.visualmode()
  if kind == "" then
    return {}
  end
  return vim.fn.getregion(vim.fn.getpos("'<"), vim.fn.getpos("'>"), { type = kind })
end

--- The sql `opts` names: the lines of a command's range, the visual selection,
--- or the whole buffer.
---@param opts dbquery.Source
---@return string
local function sqlText(opts)
  local lines
  if opts.range then
    lines = vim.api.nvim_buf_get_lines(0, opts.range[1] - 1, opts.range[2], false)
  elseif opts.visual then
    lines = selectedLines()
  else
    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end
  return vim.trim(table.concat(lines, "\n"))
end

--- Runs `request.sql` against the connection and shows what the client writes
--- in `request.srcWin`'s output window, with an indicator beside the query and
--- the key that stops it bound while it runs.
---
--- A transcript is worth watching fill in, so the window follows the file as it
--- is written. Rows are worth reading only once they are all there, and
--- rendering a half written table every half second is expensive on exactly the
--- results large enough to need the wait.
---
--- The client is given `request.resolved`, which may hold a password an
--- environment variable named. The output buffer carries `request.url` instead,
--- the connection as it was written, which is what `b:db` holds everywhere else.
--- That is absent when the connection came from vim-dadbod's own chain rather
--- than from this buffer, and then the output buffer records none.
---@param request { url: string|nil, resolved: string, sql: string, mode: dbquery.Mode, srcWin: integer, srcBuf: integer, srcName: string }
local function runInPane(request)
  local srcWin = request.srcWin
  -- One query per window, so starting a second one asks the first to stop
  -- rather than leaving a client running that nothing holds a handle to.
  pane.stop(srcWin)

  local stopIndicator = pane.progress(srcWin, request.srcBuf, config.cancel)
  local stopFollowing, run, started

  started = query.start({
    url = request.resolved,
    sql = request.sql,
    mode = request.mode,
    on_done = function(code)
      stopIndicator()
      if stopFollowing then
        stopFollowing()
      elseif code == 0 then
        pane.show(srcWin, started.path, request.url)
      end
      pane.release(srcWin, run)
    end,
  })

  if not started then
    stopIndicator()
    return
  end

  run = started.run
  pane.attach(srcWin, run)
  if request.mode == "script" then
    stopFollowing = pane.follow(srcWin, started.path, request.url)
  end
end

--- Asks which database this buffer speaks to and assigns it, then calls
--- `chosen` with the url. A cancelled choice calls nothing.
---
--- The connection is remembered in `g:db` as well, which is what gives the next
--- sql buffer a connection without being asked again.
---@param chosen fun(url: string)|nil
function M.connect(chosen)
  local list, err = connections.list(config.connections)
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
    vim.b[buf].db_name = choice.name
    vim.b[buf].db = choice.url
    vim.g.db = choice.url
    if chosen then
      chosen(choice.url)
    end
  end)
end

--- How to run `sql` to get `format` out of it.
---
--- Text is what the client prints for itself, and every statement can be run
--- that way. Csv is a rendering of one result set, so it is asked for only when
--- the sql is the single row-returning statement that can fill one, and
--- anything else falls back to text rather than failing.
---@param sql string
---@param format dbquery.Format
---@return dbquery.Mode
local function modeFor(sql, format)
  if format == "csv" then
    return query.mode(sql)
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
--- out, which is how the caller knows to ask for a connection.
---@param url string|nil
---@return string|nil
local function resolve(url)
  local ok, resolved = pcall(vim.fn["db#resolve"], url or "")
  if ok then
    return resolved
  end
  return url
end

--- Runs the sql `opts` names, asking for a connection first when the buffer has
--- none.
---
--- The sql is read before the chooser opens, because choosing ends visual mode
--- and takes the selection with it.
---@param opts dbquery.Source|{ format: dbquery.Format|nil }|nil Defaults to the whole buffer as text.
function M.execute(opts)
  opts = opts or {}
  local sql = sqlText(opts)
  if sql == "" then
    return vim.notify("db-query: no query to run", vim.log.levels.WARN)
  end

  local mode = modeFor(sql, opts.format or config.format or "text")
  -- Captured now, because choosing a connection gives the user time to move
  -- somewhere else before the query starts.
  local srcWin = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local srcName = vim.api.nvim_buf_get_name(buf)

  ---@param url string|nil
  ---@param resolved string
  local function start(url, resolved)
    runInPane({
      url = url,
      resolved = resolved,
      sql = sql,
      mode = mode,
      srcWin = srcWin,
      srcBuf = buf,
      srcName = srcName,
    })
  end

  local resolved = resolve(vim.b.db)
  if resolved then
    return start(vim.b.db, resolved)
  end

  M.connect(function(url)
    start(url, resolve(url))
  end)
end

local FORMATS = { "text", "csv" }

--- The format `args` asks for, defaulting to text. Nil for arguments that name
--- no format, already reported, so the caller runs nothing.
---@param args string[]
---@return dbquery.Format|nil
local function parseFormat(args)
  local format = "text"
  local index = 1
  while index <= #args do
    if args[index] ~= "-f" then
      vim.notify("db-query: unknown argument " .. args[index], vim.log.levels.ERROR)
      return nil
    end
    format = args[index + 1]
    if not vim.tbl_contains(FORMATS, format) then
      vim.notify("db-query: -f wants " .. table.concat(FORMATS, " or "), vim.log.levels.ERROR)
      return nil
    end
    index = index + 2
  end
  return format
end

--- What completes the word being typed: a format after `-f`, and `-f` itself
--- anywhere else.
---@param lead string
---@param line string
---@return string[]
local function completeArgs(lead, line)
  local offered = line:match("%-f%s+%S*$") and FORMATS or { "-f" }
  return vim.tbl_filter(function(word)
    return vim.startswith(word, lead)
  end, offered)
end

---@param opts dbquery.Config|nil
function M.setup(opts)
  config = vim.tbl_extend("force", config, opts or {})
  -- A query that cannot be cancelled runs until the server gives up, so there
  -- is no way to turn this off, only to move it.
  if type(config.cancel) ~= "string" or config.cancel == "" then
    error("db-query: cancel must be a key, such as '<C-c>'")
  end

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

  vim.api.nvim_create_user_command("DBQuery", function(command)
    local format = parseFormat(command.fargs)
    if not format then
      return
    end
    local range = command.range > 0 and { command.line1, command.line2 } or nil
    M.execute({ range = range, format = format })
  end, {
    range = true,
    nargs = "*",
    complete = completeArgs,
    desc = "Run the selection, or the whole buffer",
  })

  vim.api.nvim_create_user_command("DBConnect", function()
    M.connect()
  end, { desc = "Choose the database this buffer speaks to" })

  if config.parquet then
    require("db-query.parquet").setup(group)
  end
end

return M
