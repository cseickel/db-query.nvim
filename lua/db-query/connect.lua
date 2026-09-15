--[[
Which connection a sql buffer runs against.

A buffer takes its connection from its modeline when it has one, and from the
`g:db` the last pick left behind when it does not. `:DBConnect` and a query in
a buffer without a connection open the picker.

A connection from the modeline or the picker is tested with `select 1` before
it is stored. One that answers goes in `b:db` and `b:db_name`. One that does
not leaves `b:db` empty and `b:db_name` reading "<name> CONNECTION ERROR". A
sqlite or duckdb file passes without a test, because opening it would create a
missing file or fail on another process's lock. A query asked for while a test
runs is refused, because `b:db` still holds the connection the test may
replace.
]]

local catalog = require("db-query.catalog")
local client = require("db-query.client")
local config = require("db-query.config")
local connections = require("db-query.connections")
local dadbod = require("db-query.dadbod")
local modeline = require("db-query.modeline")
local Source = require("db-query.source")
local sql = require("db-query.sql")

local M = {}

local TIMEOUT = 10000

--- The `g:db` this plugin set, which is what `g:db_name` names. Setting `g:db`
--- by hand leaves the old name behind, and a winbar naming the wrong database
--- is worse than one naming none.
---@type string|nil
local namedUrl = nil

---@class dbquery.Attempt
---@field connection dbquery.Connection

--- The test pending for each buffer. Only the latest counts, so a slow test
--- cannot overwrite a connection chosen after it began.
---@type table<integer, dbquery.Attempt>
local attempts = {}

--- Returns the lines the indicator marks while `buf` tests a connection: the
--- modeline, or else the statement at the cursor, or else the cursor's line.
---@param buf integer
---@param dialect dbquery.Dialect
---@return [integer, integer]
local function testedAt(buf, dialect)
  local line = modeline.find(buf)
  if line then
    return { line.row, line.row }
  end
  local win = vim.fn.win_findbuf(buf)[1]
  local row = win and vim.api.nvim_win_get_cursor(win)[1] - 1 or 0
  return sql.statementAt(dialect, vim.api.nvim_buf_get_lines(buf, 0, -1, false), row) or { row, row }
end

--- Runs `select 1` against `connection` without blocking, shown in `buf` by
--- an indicator that can cancel it, and calls `done` on the main loop with
--- whether it answered and, when it did not, why. A server that says nothing
--- within TIMEOUT fails, and so does a cancelled test.
---@param buf integer
---@param connection dbquery.Connection
---@param done fun(answered: boolean, reason: string|nil)
local function test(buf, connection, done)
  local resolved = dadbod.resolve(connection.url)
  if resolved and client.embedded(resolved) then
    return done(true)
  end
  local dialect = resolved and client.dialect(resolved)
  if not (resolved and dialect) then
    return done(false)
  end
  local process, err = client.value({
    connection = resolved,
    statement = "select 1",
    timeout = TIMEOUT,
    readonly = false,
  })
  if not process then
    return done(false, err)
  end

  Source.of(buf):test(process, testedAt(buf, dialect), connection.name)
  process:onFinish(function()
    done(process.status == "ok", process:reason())
  end)
end

--- Forgets the test pending for `buf`, cancelling it.
---@param buf integer
local function abandon(buf)
  if attempts[buf] then
    attempts[buf] = nil
    Source.of(buf):cancel()
  end
end

---@param buf integer
---@param name string
local function unreachable(buf, name)
  vim.b[buf].db = nil
  vim.b[buf].db_name = name .. " CONNECTION ERROR"
end

--- Tests `connection` and gives it to `buf` when it answers. `done` gets the
--- outcome, and is skipped when `buf` was closed or given another connection
--- while the test ran.
---@param buf integer
---@param connection dbquery.Connection
---@param done fun(answered: boolean)|nil
local function assign(buf, connection, done)
  local attempt = { connection = connection }
  attempts[buf] = attempt

  test(buf, connection, function(answered, reason)
    if attempts[buf] ~= attempt then
      return
    end
    attempts[buf] = nil
    if not vim.api.nvim_buf_is_loaded(buf) then
      return
    end

    if answered then
      vim.b[buf].db_name = connection.name
      vim.b[buf].db = connection.url
      dadbod.refetch(buf)
      local resolved = dadbod.resolve(connection.url)
      if resolved then
        catalog.refresh(resolved)
      end
    else
      unreachable(buf, connection.name)
      if reason then
        vim.notify("db-query: cannot connect to " .. connection.name .. ": " .. reason, vim.log.levels.ERROR)
      end
    end
    if done then
      done(answered)
    end
  end)
end

--- Returns the name of the connection being tested for `buf`, or nil when no
--- test is pending.
---@param buf integer
---@return string|nil
function M.testing(buf)
  return attempts[buf] and attempts[buf].connection.name
end

--- Connects `buf` to the connection its modeline names, testing it first unless
--- `buf` is already connected to it or testing it now. A name missing from the
--- connection list is a failed connection.
---
--- Returns false when `buf` has no modeline naming a connection, which leaves
--- `buf` on whatever connection it had.
---@param buf integer
---@return boolean
function M.follow(buf)
  local line = modeline.find(buf)
  if not line then
    return false
  end
  if not line.connection then
    vim.notify(
      "db-query: the @db-query line on line " .. line.row + 1 .. " names no connection",
      vim.log.levels.WARN
    )
    return false
  end

  local connection, err = connections.named(config.values.connections, line.connection)
  if not connection then
    abandon(buf)
    unreachable(buf, line.connection)
    vim.notify("db-query: " .. err, vim.log.levels.ERROR)
    return true
  end

  local pending = attempts[buf] and attempts[buf].connection
  if pending and pending.name == connection.name and pending.url == connection.url then
    return true
  end
  if vim.b[buf].db == connection.url and vim.b[buf].db_name == connection.name then
    abandon(buf)
  else
    assign(buf, connection)
  end
  return true
end

--- Gives a newly opened sql buffer its connection: the modeline's, or else the
--- `g:db` the last pick set, which is untested because only a connection that
--- answered is ever put there.
---@param buf integer
function M.opened(buf)
  if M.follow(buf) then
    return
  end
  if vim.g.db and not vim.b[buf].db then
    vim.b[buf].db = vim.g.db
    if vim.g.db == namedUrl then
      vim.b[buf].db_name = vim.g.db_name
    end
  end
end

--- Opens the connection picker for `buf`, tests the choice, and connects `buf`
--- to it when it answers, then calls `chosen` with it. A cancelled picker does
--- nothing.
---
--- In a buffer whose modeline names another connection, the choice rewrites
--- the modeline after a confirm, and cancelling the confirm leaves both the
--- modeline and the connection alone. Otherwise the choice also goes in `g:db`,
--- so later sql buffers start on it without asking.
---
--- `buf` is taken rather than read at the end, because the picker may open long
--- after the query was asked for and the user is free to move in the meantime.
---@param buf integer|nil Buffer to connect (default: the current one).
---@param chosen fun(connection: dbquery.Connection)|nil
function M.pick(buf, chosen)
  local list, err = connections.list(config.values.connections)
  if err then
    return vim.notify("db-query: " .. err, vim.log.levels.ERROR)
  end
  if #list == 0 then
    return vim.notify("db-query: no connections configured", vim.log.levels.WARN)
  end

  buf = buf or vim.api.nvim_get_current_buf()
  vim.ui.select(list, {
    prompt = "Database",
    format_item = function(connection)
      return connection.name
    end,
  }, function(choice)
    if not (choice and vim.api.nvim_buf_is_loaded(buf)) then
      return
    end

    local line = modeline.find(buf)
    local pinned = line and line.connection or nil
    if line and pinned and pinned ~= choice.name then
      local question = string.format(
        "The modeline connects this file to %s. Replace it with %s?",
        pinned,
        choice.name
      )
      if vim.fn.confirm(question, "&Replace\n&Cancel", 2) ~= 1 then
        return
      end
      modeline.rewrite(buf, line, choice.name)
    end

    assign(buf, choice, function(answered)
      if not answered then
        return
      end
      if not pinned then
        vim.g.db = choice.url
        vim.g.db_name = choice.name
        namedUrl = choice.url
      end
      if chosen then
        chosen(choice)
      end
    end)
  end)
end

return M
