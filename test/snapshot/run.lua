--[[
Checks the plugin against real sqlite and duckdb databases by comparing its
answers with the files in `expected/`.
]]

local DIR = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local UPDATE = vim.tbl_contains(arg or {}, "update")
vim.opt.rtp:prepend(vim.fn.fnamemodify(DIR, ":h:h"))

local cases = dofile(DIR .. "/cases.lua")
local lsp = dofile(DIR .. "/lsp.lua")
local dbquery = require("db-query")

local TMP = vim.fn.tempname() .. "-db-query"
local OUT = TMP .. "/out"
vim.fn.mkdir(OUT, "p")
local CACHE = vim.fn.stdpath("cache") .. "/db-query"
local RUN_DIR = CACHE .. "/" .. vim.fn.getpid()
local SEPARATOR = string.rep("-", 80)

local notes = {}
vim.notify = function(message, level)
  table.insert(notes, "notify[" .. tostring(level or 0) .. "] " .. tostring(message))
end
vim.ui.select = function()
  table.insert(notes, "ui.select called")
end
vim.ui.input = function()
  table.insert(notes, "ui.input called")
end

--- Returns `text` with the paths and times that change from run to run
--- replaced by placeholders.
---@param text string
---@return string
local function normalize(text)
  text = text:gsub(vim.pesc(TMP), "<TMP>")
  text = text:gsub(vim.pesc(RUN_DIR), "<RUNDIR>")
  text = text:gsub(vim.pesc(CACHE), "<CACHE>")
  text = text:gsub("/definitions/%x+/", "/definitions/<HASH>/")
  text = text:gsub("%d%d:%d%d:%d%d", "<HH:MM:SS>")
  text = text:gsub("%d+%.%d+s", "<T>s")
  text = text:gsub("%d+ms", "<T>ms")
  return text
end

---@class snapshot.Results
---@field names string[] Case names, in the order they ran.
---@field texts table<string, string>

--- Returns a results list whose `record` adds a case's text, followed by any
--- notifications shown since the last case.
---@return snapshot.Results results
---@return fun(name: string, text: string) record
local function recorder()
  local results = { names = {}, texts = {} }
  return results, function(name, text)
    if #notes > 0 then
      text = text .. "\n-- notifications --\n" .. table.concat(notes, "\n")
      notes = {}
    end
    assert(results.texts[name] == nil, "duplicate case " .. name)
    table.insert(results.names, name)
    results.texts[name] = normalize(text)
  end
end

--- Returns the log `engine`'s buffer writes to.
---@param engine string
---@return string|nil
local function logPath(engine)
  return vim.fn.glob(RUN_DIR .. "/*/" .. engine .. ".md", false, true)[1]
end

--- Returns how many runs the log of `engine`'s buffer has closed.
---@param engine string
---@return integer
local function closedRuns(engine)
  local path = logPath(engine)
  return path and select(2, lsp.readFile(path):gsub(vim.pesc(SEPARATOR), "")) or 0
end

---@param buf integer
local function waitForIdle(buf)
  vim.wait(10000, function()
    return dbquery.statusline(buf) == ""
  end, 50)
end

---@param engine snapshot.Engine
---@param record fun(name: string, text: string)
local function check(engine, record)
  local database = TMP .. "/" .. engine.name .. ".db"
  local created = vim.system({ engine.binary, database }, { stdin = engine.schema, text = true }):wait()
  if created.code ~= 0 then
    error(engine.binary .. " could not create the database: " .. (created.stderr or ""))
  end
  local buf = lsp.open(TMP .. "/" .. engine.name .. ".sql", engine.name .. ":" .. database)

  record("statusline_before", "[" .. dbquery.statusline(buf) .. "]")
  local loaded = vim.wait(30000, function()
    return lsp.complete(buf, "select | from orders", nil, {}):find('label = "customer_id"', 1, true) ~= nil
  end, 200)
  waitForIdle(buf)
  notes = {}
  record("catalog_loaded", tostring(loaded))

  for _, case in ipairs(vim.list_extend(vim.deepcopy(cases.completions), engine.completions)) do
    record("complete/" .. case[1], case[2] .. "\n" .. lsp.complete(buf, case[2], case[3], engine.functions))
  end
  for _, case in ipairs(vim.list_extend(vim.deepcopy(cases.hovers), engine.hovers)) do
    record("hover/" .. case[1], case[2] .. "\n" .. lsp.hover(buf, case[2]))
  end
  for _, case in ipairs(vim.list_extend(vim.deepcopy(cases.signatures), engine.signatures)) do
    record("signature/" .. case[1], case[2] .. "\n" .. lsp.signature(buf, case[2]))
  end
  for _, case in ipairs(vim.list_extend(vim.deepcopy(cases.definitions), engine.definitions)) do
    record("definition/" .. case[1], case[2] .. "\n" .. lsp.definition(buf, case[2]))
  end
  for _, case in ipairs(cases.references) do
    record("references/" .. case[1], case[2] .. "\n" .. lsp.references(buf, case[2], case[3]))
  end

  for _, query in ipairs(cases.queries) do
    lsp.focus(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(query.sql, "\n"))
    vim.api.nvim_win_set_cursor(0, { (query.row or 0) + 1, 0 })
    local before = closedRuns(engine.name)
    dbquery.execute(query.opts)
    local finished = vim.wait(30000, function()
      return closedRuns(engine.name) > before
    end, 50)
    vim.wait(300)
    waitForIdle(buf)
    record("query/" .. query.name, "finished=" .. tostring(finished))
  end

  local log = logPath(engine.name)
  record("log", log and lsp.readFile(log) or "<no log>")
  local written = vim.fn.glob(OUT .. "/" .. engine.name .. "-*", false, true)
  table.sort(written)
  record("results", table.concat(vim.tbl_map(function(path)
    return "== " .. path .. "\n" .. lsp.readFile(path)
  end, written), "\n"))
  record("statusline_after", "[" .. dbquery.statusline(buf) .. "]")
end

--- Returns `results` as the text of an expected file.
---@param results snapshot.Results
---@return string
local function serialize(results)
  return table.concat(vim.tbl_map(function(name)
    return "##### " .. name .. "\n" .. results.texts[name] .. "\n"
  end, results.names))
end

--- Returns the cases in the text of an expected file.
---@param text string
---@return table<string, string>
local function parse(text)
  local texts, name, lines = {}, nil, {}
  for line in (text .. "##### \n"):gmatch("([^\n]*)\n") do
    local heading = line:match("^##### (.*)$")
    if heading then
      if name then
        texts[name] = table.concat(lines, "\n")
      end
      name, lines = heading, {}
    else
      lines[#lines + 1] = line
    end
  end
  return texts
end

--- Prints each case that differs from `expectedPath`, with a diff, and
--- returns how many differ.
---@param results snapshot.Results
---@param expectedPath string
---@return integer
local function compare(results, expectedPath)
  local expected = parse(lsp.readFile(expectedPath))
  local differences = 0
  for _, name in ipairs(results.names) do
    local actual = results.texts[name]
    if expected[name] == nil then
      differences = differences + 1
      io.stdout:write("NEW     " .. name .. "\n")
    elseif expected[name] ~= actual then
      differences = differences + 1
      io.stdout:write("CHANGED " .. name .. "\n" .. vim.diff(expected[name] .. "\n", actual .. "\n"))
    end
    expected[name] = nil
  end
  for name in pairs(expected) do
    differences = differences + 1
    io.stdout:write("MISSING " .. name .. "\n")
  end
  return differences
end

dbquery.setup({ output_dir = OUT, format = "text" })
vim.wait(200)

local failed = false
for _, engine in ipairs(cases.engines) do
  local expectedPath = DIR .. "/expected/" .. engine.name .. ".txt"
  if vim.fn.executable(engine.binary) == 0 then
    io.stdout:write(engine.name .. ": skipped, " .. engine.binary .. " is not installed\n")
  else
    local results, record = recorder()
    local ok, err = pcall(check, engine, record)
    if not ok then
      record("error", tostring(err))
    end
    if UPDATE then
      vim.fn.mkdir(DIR .. "/expected", "p")
      vim.fn.writefile(vim.split(serialize(results), "\n", { plain = true }), expectedPath, "b")
      io.stdout:write(engine.name .. ": wrote " .. expectedPath .. "\n")
    else
      local differences = compare(results, expectedPath)
      io.stdout:write(string.format("%s: %d cases, %d differences\n", engine.name, #results.names, differences))
      if differences > 0 then
        failed = true
        -- nvim deletes its own temp directory when it exits.
        local actualPath = os.tmpname()
        vim.fn.writefile(vim.split(serialize(results), "\n", { plain = true }), actualPath, "b")
        io.stdout:write(engine.name .. ": this run's output is in " .. actualPath .. "\n")
      end
    end
  end
end

vim.fn.delete(TMP, "rf")
vim.cmd(failed and "cquit 1" or "qall!")
