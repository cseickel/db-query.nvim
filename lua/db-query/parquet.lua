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

--- Creates a view for `path` in the shared database. Returns nil on failure.
---@param path string
---@return string|nil name
local function define(path)
  local name = vim.fn.fnamemodify(path, ":t:r")
  local sql = string.format(
    "create or replace view %s as select * from %s;",
    identifier(name),
    literal(path)
  )
  if client.run(URL, sql) == nil then
    return nil
  end
  return name
end

--- Returns the initial query for `path`. Falls back to querying by path if
--- view creation fails.
---@param path string
---@return { url: string, lines: string[] }
local function opening(path)
  local name = define(path)
  if not name then
    return {
      url = "duckdb:",
      lines = { "select *", "from " .. literal(path), "limit 1000;" },
    }
  end
  return {
    url = URL,
    lines = { "select *", "from " .. identifier(name), "limit 1000;" },
  }
end

---@param group integer
function M.setup(group)
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = "*.parquet",
    callback = function(event)
      local path = vim.fn.fnamemodify(event.match, ":p")

      vim.fn.mkdir(SCRATCH, "p")
      vim.api.nvim_buf_set_name(
        event.buf,
        string.format("%s/%s.sql", SCRATCH, vim.fn.fnamemodify(path, ":t:r"))
      )

      local opened = opening(path)
      vim.api.nvim_buf_set_lines(event.buf, 0, -1, false, opened.lines)
      vim.bo[event.buf].filetype = "sql"
      vim.b[event.buf].db = opened.url
      vim.bo[event.buf].modified = false

      -- Scheduled because execute opens a window during BufReadCmd.
      vim.schedule(function()
        if vim.api.nvim_get_current_buf() == event.buf then
          require("db-query").execute({ format = "csv" })
        end
      end)
    end,
  })
end

return M
