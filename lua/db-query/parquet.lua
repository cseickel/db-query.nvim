--[[
BufReadCmd handler for *.parquet files.

Opens a duckdb query against the parquet file instead of showing binary
content. The file is registered as a view so sql completion includes its
columns.

Disabled by default; requires `parquet = true` in setup().
]]

local client = require("db-query.client")

local M = {}

-- Shared database per nvim; duckdb takes an exclusive lock.
local URL = "duckdb:" .. vim.fn.tempname() .. ".duckdb"
local SCRATCH = vim.fn.stdpath("cache") .. "/parquet"

---@param text string
---@return string
local function literal(text)
  return "'" .. text:gsub("'", "''") .. "'"
end

---@param name string
---@return string
local function identifier(name)
  return '"' .. name:gsub('"', '""') .. '"'
end

--- Creates a view for `path` in the shared database, then calls `opened` with
--- the url and lines of the query against it. When the view cannot be created,
--- the query reads the file by its path instead.
---@param path string
---@param opened fun(url: string, lines: string[])
local function open(path, opened)
  local name = vim.fn.fnamemodify(path, ":t:r")
  local byPath = { "select *", "from " .. literal(path), "limit 1000;" }

  local process, err = client.value(URL, string.format(
    "create or replace view %s as select * from %s;",
    identifier(name),
    literal(path)
  ))
  if not process then
    if err then
      vim.notify("db-query: " .. err, vim.log.levels.ERROR)
    end
    -- Scheduled, because the query opens a window, which BufReadCmd forbids.
    return vim.schedule(function()
      opened("duckdb:", byPath)
    end)
  end

  process:onFinish(function(_, result)
    if process.status ~= "ok" then
      vim.notify("db-query: " .. vim.trim(result.stderr or "create view failed"), vim.log.levels.ERROR)
      return opened("duckdb:", byPath)
    end
    opened(URL, { "select *", "from " .. identifier(name), "limit 1000;" })
  end)
end

---@param group integer
function M.setup(group)
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "*.parquet",
    callback = function(event)
      local path = vim.fn.fnamemodify(event.match, ":p")
      local buf = event.buf

      vim.fn.mkdir(SCRATCH, "p")
      vim.api.nvim_buf_set_name(buf, string.format("%s/%s.sql", SCRATCH, vim.fn.fnamemodify(path, ":t:r")))

      open(path, function(url, lines)
        if not vim.api.nvim_buf_is_loaded(buf) then
          return
        end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        -- Before the filetype, whose autocmd gives a buffer with no b:db the g:db
        -- connection and its name.
        vim.b[buf].db = url
        vim.bo[buf].filetype = "sql"
        vim.bo[buf].modified = false

        if vim.api.nvim_get_current_buf() == buf then
          require("db-query").execute({ format = "csv" })
        end
      end)
    end,
  })
end

return M
