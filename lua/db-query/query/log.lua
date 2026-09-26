--[[
How a sql buffer's log reads.

The buffer has one Log, holding the file every one of its runs appends to. Each
run takes an entry in that log, which holds the run's number and its clock. The
run opens its entry with `query`, the client appends what it prints to
`entry.path` while it runs, and one completion message closes the entry. Every
format decision lives here, so a caller hands over raw text and says which kind
of message it is.
]]

local runStatus = require("db-query.query.status")
local output = require("db-query.query.files")

---@alias dbquery.LogMessage
---| "query" # The sql about to run, which opens the entry.
---| "output" # Text belonging to the client's transcript.
---| "success_complete" # The run finished, which closes the entry.
---| "error_complete" # The run failed, which closes the entry.
---| "cancel_complete" # The run was cancelled, which closes the entry.

---@class dbquery.Log
---@field path string The file every run of one sql buffer appends to.
---@field runs integer Entries taken so far, which is what numbers each one.
local Log = {}
Log.__index = Log

--- One run's place in the log. A cancelled run and the run replacing it are
--- alive at the same time, so each carries its own number and clock.
---@class dbquery.LogEntry
---@field path string The file, which the client appends to directly.
---@field id integer Distinguishes runs sharing the file.
---@field name string|nil Connection's chosen name.
---@field rows string|nil Results file, when the statement returns rows.
---@field started integer hrtime nanoseconds.
local Entry = {}
Entry.__index = Entry

--- Fences the sql, and fences what the client prints.
---
--- The output fence is the longer of the two, so that neither a sql fence nor a
--- client printing three backticks can end the block the client writes into.
---
--- Only the bare closing fence toggles a block, since a fence with an info
--- string can only open one. A cancelled query still writing while its
--- replacement opens an entry therefore leaves a block open, and the run after
--- the two of them closes it. Those three read wrong and the next one is clean.
local SQL_FENCE = "```"
local OUTPUT_FENCE_OPEN = "~~~~ bash\n"
local OUTPUT_FENCE_CLOSE = "~~~~"
local SEPARATOR = string.rep("-", 80)

---@class dbquery.LogEnding
---@field status dbquery.Status Picks the icon, and the color the line is drawn in.
---@field word string

--- How each completion is written.
---@type table<dbquery.LogMessage, dbquery.LogEnding>
local ENDED = {
  success_complete = { status = "ok", word = "Finished" },
  error_complete = { status = "failed", word = "Failed" },
  cancel_complete = { status = "cancelled", word = "Cancelled" },
}

---@param path string
---@param text string
local function append(path, text)
  local file = io.open(path, "a")
  if file then
    file:write(text)
    file:close()
  end
end

--- Whether `path` is empty or ends in a newline, and so whether the next thing
--- appended to it starts a line.
---@param path string
---@return boolean
local function atLineStart(path)
  local file = io.open(path, "r")
  if not file then
    return true
  end
  local size = file:seek("end")
  local last = size > 0 and file:seek("set", size - 1) and file:read(1) or "\n"
  file:close()
  return last == "\n"
end

--- Opens the entry with what is about to run, so the pane has something to show
--- before the client prints anything. The block the client writes into is left
--- open, and a completion closes it.
---
--- The id repeats in the status line, because a cancelled query goes on writing
--- while its replacement is already appending to the same file.
---@param self dbquery.LogEntry
---@param sql string
local function opening(self, sql)
  local heading = { "# " .. self.id, os.date("%H:%M:%S") }
  if self.name then
    table.insert(heading, self.name)
  end

  local lines = { table.concat(heading, " · "), "" }
  vim.list_extend(lines, {
    SQL_FENCE .. "sql",
    sql,
    SQL_FENCE,
    "",
    OUTPUT_FENCE_OPEN,
  })
  append(self.path, table.concat(lines, "\n"))
end

--- Closes the block the client writes into and states how the run ended. Every
--- `query` message is answered by exactly one completion, which is what leaves
--- the log with no block open. A success that wrote rows names the results
--- file inside the block.
---
--- A client whose last line has no newline gets one, since a closing fence is
--- only a fence at the start of a line.
---@param self dbquery.LogEntry
---@param ended dbquery.LogEnding
local function closing(self, ended)
  local seconds = (vim.uv.hrtime() - self.started) / 1e9
  local completion = string.format("%s %s in %.3fs", runStatus.icon(ended.status), ended.word, seconds)

  local lines = {}
  if ended.status == "ok" and self.rows then
    table.insert(lines, "saved to " .. self.rows)
  else
    if not atLineStart(self.path) then
      table.insert(lines, "")
    end
  end
  vim.list_extend(lines, { OUTPUT_FENCE_CLOSE, "", completion, "", SEPARATOR, "", "" })
  append(self.path, table.concat(lines, "\n"))
end

--- Returns the log for `ctx`'s buffer, or nil when the file cannot be written.
---@param ctx dbquery.Context
---@return dbquery.Log|nil
function Log.open(ctx)
  local path = output.log(ctx.buf, ctx.srcName)
  if not path then
    return nil
  end
  return setmetatable({ path = path, runs = 0 }, Log)
end

--- Returns the entry for one run, whose duration is measured from here.
---@param ctx dbquery.Context
---@param rows string|nil Results file, when the statement returns rows.
---@return dbquery.LogEntry
function Log:entry(ctx, rows)
  self.runs = self.runs + 1
  return setmetatable({
    path = self.path,
    id = self.runs,
    name = ctx.name,
    rows = rows,
    started = vim.uv.hrtime(),
  }, Entry)
end

---@param message dbquery.LogMessage
---@param text string|nil The sql for "query" and the text for "output". A completion carries none.
function Entry:append(message, text)
  if message == "query" then
    return opening(self, text or "")
  end
  if message == "output" then
    return append(self.path, text or "")
  end
  return closing(self, ENDED[message])
end

return Log
