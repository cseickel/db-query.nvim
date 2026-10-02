--[[
Registers the user commands and parses their arguments.
]]

local M = {}

local FORMATS = { "text", "csv" }
local FLAGS = { "-f", "-o" }
local VIEWS = { "log", "result", "toggle" }

---@param lead string
---@param words string[]
---@return string[]
local function matching(lead, words)
  return vim.tbl_filter(function(word)
    return vim.startswith(word, lead)
  end, words)
end

---@param lead string
---@param line string
---@return string[]
local function complete(lead, line)
  if line:match("%-o%s+%S*$") then
    return vim.fn.getcompletion(lead, "file")
  end
  return matching(lead, line:match("%-f%s+%S*$") and FORMATS or FLAGS)
end

--- Runs `selection` with the format and output that `args` give. Shows an
--- error and runs nothing for a flag other than `-f` and `-o`, and for `-f`
--- given anything but text or csv.
---@param api dbquery.Api
---@param selection dbquery.Selection
---@param args string[]
local function run(api, selection, args)
  ---@type dbquery.ExecuteOptions
  local opts = { range = selection.range, statement = selection.statement, format = "text" }
  local index = 1
  while index <= #args do
    local flag, value = args[index], args[index + 1]
    local hasValue = value ~= nil and not vim.startswith(value, "-")

    if flag == "-f" then
      if not (hasValue and vim.tbl_contains(FORMATS, value)) then
        return vim.notify("db-query: -f wants " .. table.concat(FORMATS, " or "), vim.log.levels.ERROR)
      end
      opts.format = value
      index = index + 2
    elseif flag == "-o" then
      opts.output = hasValue and value or true
      index = index + (hasValue and 2 or 1)
    else
      return vim.notify("db-query: unknown argument " .. flag, vim.log.levels.ERROR)
    end
  end
  api.execute(opts)
end

--- Registers all user commands, each calling the function of `api` it names.
---@param api dbquery.Api
function M.setup(api)
  vim.api.nvim_create_user_command("DBQuery", function(command)
    local range = command.range > 0 and { command.line1, command.line2 } or nil
    run(api, { range = range }, command.fargs)
  end, {
    range = true,
    nargs = "*",
    complete = complete,
    desc = "Execute the query for the whole buffer or selection",
  })

  vim.api.nvim_create_user_command("DBQueryStatement", function(command)
    run(api, { statement = true }, command.fargs)
  end, {
    nargs = "*",
    complete = complete,
    desc = "Run the statement that the cursor is on",
  })

  vim.api.nvim_create_user_command("DBConnect", function()
    api.connect()
  end, { desc = "Choose the database this buffer connects to" })

  vim.api.nvim_create_user_command("DBRefreshCatalog", function(command)
    if command.args == "" then
      return api.refreshCatalog()
    end
    if command.args == "cancel" then
      return api.cancelCatalog()
    end
    vim.notify("db-query: DBRefreshCatalog takes nothing, or cancel", vim.log.levels.ERROR)
  end, {
    nargs = "?",
    complete = function(lead)
      return matching(lead, { "cancel" })
    end,
    desc = "Read the tables, columns, and functions of this buffer's database again, or cancel the read",
  })

  vim.api.nvim_create_user_command("DBOutput", function(command)
    local view = command.args ~= "" and command.args or "toggle"
    if not vim.tbl_contains(VIEWS, view) then
      return vim.notify(
        "db-query: DBOutput wants " .. table.concat(VIEWS, ", "),
        vim.log.levels.ERROR
      )
    end
    api.output(view)
  end, {
    nargs = "?",
    complete = function(lead)
      return matching(lead, VIEWS)
    end,
    desc = "Show the log or the last query's result (default: toggle)",
  })

  vim.api.nvim_create_user_command("DBOutputDir", function(command)
    api.outputDir(command.args ~= "" and command.args or nil)
  end, {
    nargs = "?",
    complete = "dir",
    desc = "Choose output directory",
  })
end

return M
