--[[
Configuration values and defaults.

Other modules read config.values directly.
]]

local M = {}

---@alias dbquery.Format "text"|"csv"

---@class dbquery.Config
---@field connections? dbquery.Connection[]|fun(): dbquery.Connection[]|nil
---@field parquet boolean Enable *.parquet handling.
---@field cancel string Cancel keybinding.
---@field format dbquery.Format Default output format.
---@field output_dir string|nil Output directory (nil = cache).
---@field output_cleanup boolean Delete files on window close.

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
  -- Default: auto-cleanup only when no custom output_dir is set.
  if given.output_cleanup == nil then
    M.values.output_cleanup = M.values.output_dir == nil
  end
  -- Expand ~ now to avoid creating a literal directory named "~".
  if M.values.output_dir then
    M.values.output_dir = vim.fs.normalize(M.values.output_dir)
  end
  if type(M.values.cancel) ~= "string" or M.values.cancel == "" then
    vim.notify("db-query: cancel must be a key, such as '<C-c>'", vim.log.levels.WARN)
    M.values.cancel = "<C-c>"
  end
end

return M
