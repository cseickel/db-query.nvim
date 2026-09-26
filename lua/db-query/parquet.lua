--[[
Opens a *.parquet file as a duckdb query against it, instead of its binary
content. The file is registered as a view so sql completion includes its
columns.
]]

local client = require("db-query.client")
local duckdb = require("db-query.client.duckdb")
local query = require("db-query.client.query")

local M = {}

-- Shared database per nvim; duckdb takes an exclusive lock.
local URL = "duckdb:" .. vim.fn.tempname() .. ".duckdb"
local SCRATCH = vim.fn.stdpath("cache") .. "/parquet"

--- Creates a view for `path` in the shared database, then calls `opened` with
--- the url and lines of the query against it. When the view cannot be created,
--- the query reads the file by its path instead.
---@param path string
---@param opened fun(url: string, lines: string[])
local function open(path, opened)
  local name = vim.fn.fnamemodify(path, ":t:r")
  local view = query.qualified(duckdb.dialect, name)
  local byPath = { "select *", "from " .. query.literal(path), "limit 1000;" }

  local process, err = client.value({
    client = duckdb,
    connection = URL,
    statement = string.format("create or replace view %s as select * from %s;", view, query.literal(path)),
    readonly = false,
  })
  if not process then
    vim.notify("db-query: " .. tostring(err), vim.log.levels.ERROR)
    -- Deferred with vim.schedule: inside BufReadCmd `mainloop.run` sees no
    -- lock, but nvim refuses to open the output window there.
    return vim.schedule(function()
      opened("duckdb:", byPath)
    end)
  end

  process:onFinish(function(_, result)
    if process.status ~= "ok" then
      vim.notify("db-query: " .. vim.trim(result.stderr or "create view failed"), vim.log.levels.ERROR)
      return opened("duckdb:", byPath)
    end
    opened(URL, { "select *", "from " .. view, "limit 1000;" })
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
