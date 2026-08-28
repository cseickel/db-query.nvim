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
---@field output_dir string|nil Where output files are written. Nil is a directory of this nvim's own, in nvim's cache.
---@field output_cleanup boolean Whether output files are deleted with the window that showed them. True unless `output_dir` says otherwise.

---@type dbquery.Config
M.values = {
  parquet = false,
  cancel = "<C-c>",
  format = "text",
  output_cleanup = true,
}

---@param opts dbquery.Config|nil
function M.set(opts)
  local given = opts or {}
  M.values = vim.tbl_extend("force", M.values, given)
  -- A directory of your own is somewhere you put results you are keeping, so
  -- naming one is enough to say they are not to be cleared up.
  if given.output_cleanup == nil then
    M.values.output_cleanup = M.values.output_dir == nil
  end
  -- Expanded here so that nothing downstream makes a directory called `~`.
  if M.values.output_dir then
    M.values.output_dir = vim.fs.normalize(M.values.output_dir)
  end
  -- A query that cannot be cancelled runs until the server gives up, so there
  -- is no way to turn this off, only to move it.
  if type(M.values.cancel) ~= "string" or M.values.cancel == "" then
    error("db-query: cancel must be a key, such as '<C-c>'")
  end
end

return M
