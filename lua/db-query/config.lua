--[[
What `setup` was given, and the defaults for everything it was not.

This is read by the modules that act on it rather than passed down through
them, so a setting reaches its user without every function in between naming
it.
]]

local M = {}

---@alias dbquery.Format "text"|"csv"

---@class dbquery.Config
---@field connections? dbquery.Connection[]|fun(): dbquery.Connection[]|nil Where the chooser gets its list, replacing the built-in sources.
---@field parquet boolean Whether opening a `*.parquet` opens a duckdb query against it.
---@field cancel string The key that stops a running query, bound only while one runs.
---@field format dbquery.Format "text" is native cli output, "csv" export to csv.

---@type dbquery.Config
M.values = {
  parquet = false,
  cancel = "<C-c>",
  format = "text",
}

---@param opts dbquery.Config|nil
function M.set(opts)
  M.values = vim.tbl_extend("force", M.values, opts or {})
  -- A query that cannot be cancelled runs until the server gives up, so there
  -- is no way to turn this off, only to move it.
  if type(M.values.cancel) ~= "string" or M.values.cancel == "" then
    error("db-query: cancel must be a key, such as '<C-c>'")
  end
end

return M
