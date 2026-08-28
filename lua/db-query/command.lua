--[[
The commands, and the arguments they take.

`:DBQuery` and `:DBQueryStatement` differ only in which lines they run, so the
arguments are read once here and the rest of the plugin is handed what they
mean rather than what was typed.

The module the commands call is required where they call it. Commands are
registered while that module is still loading, and it is loaded by the time one
of them runs.
]]

local M = {}

local FORMATS = { "text", "csv" }
local FLAGS = { "-f", "-o" }

--- What the arguments to a query command ask for.
---@class dbquery.Arguments
---@field format dbquery.Format
---@field output string|true|nil A path to write the output to, true to be asked for one, and nil for the file this plugin names.

--- What `args` asks for, with text as the format nothing names. Nil for
--- arguments that are not these, already reported, so the caller runs nothing.
---@param args string[]
---@return dbquery.Arguments|nil
local function parse(args)
  local parsed = { format = "text" }
  local index = 1
  while index <= #args do
    local flag, value = args[index], args[index + 1]
    local given = value ~= nil and not vim.startswith(value, "-")

    if flag == "-f" then
      if not (given and vim.tbl_contains(FORMATS, value)) then
        vim.notify("db-query: -f wants " .. table.concat(FORMATS, " or "), vim.log.levels.ERROR)
        return nil
      end
      parsed.format = value
      index = index + 2
    elseif flag == "-o" then
      parsed.output = given and value or true
      index = index + (given and 2 or 1)
    else
      vim.notify("db-query: unknown argument " .. flag, vim.log.levels.ERROR)
      return nil
    end
  end
  return parsed
end

--- What completes the word being typed: a format after `-f`, a path after
--- `-o`, and the flags themselves anywhere else.
---@param lead string
---@param line string
---@return string[]
local function complete(lead, line)
  if line:match("%-o%s+%S*$") then
    return vim.fn.getcompletion(lead, "file")
  end
  local offered = line:match("%-f%s+%S*$") and FORMATS or FLAGS
  return vim.tbl_filter(function(word)
    return vim.startswith(word, lead)
  end, offered)
end

--- Runs the lines `selection` names as `args` asks for them, and runs nothing
--- when they ask for something that is not on offer.
---@param selection dbquery.Selection
---@param args string[]
local function run(selection, args)
  local parsed = parse(args)
  if not parsed then
    return
  end
  require("db-query").execute({
    range = selection.range,
    statement = selection.statement,
    format = parsed.format,
    output = parsed.output,
  })
end

--- Registers every command this plugin answers to.
function M.setup()
  vim.api.nvim_create_user_command("DBQuery", function(command)
    local range = command.range > 0 and { command.line1, command.line2 } or nil
    run({ range = range }, command.fargs)
  end, {
    range = true,
    nargs = "*",
    complete = complete,
    desc = "Run the selection, or the whole buffer",
  })

  vim.api.nvim_create_user_command("DBQueryStatement", function(command)
    run({ statement = true }, command.fargs)
  end, {
    nargs = "*",
    complete = complete,
    desc = "Run the statement the cursor is in",
  })

  vim.api.nvim_create_user_command("DBConnect", function()
    require("db-query").connect()
  end, { desc = "Choose the database this buffer speaks to" })

  vim.api.nvim_create_user_command("DBOutputDir", function(command)
    require("db-query").outputDir(command.args ~= "" and command.args or nil)
  end, {
    nargs = "?",
    complete = "dir",
    desc = "Write output to a directory of your own, and keep it",
  })
end

return M
