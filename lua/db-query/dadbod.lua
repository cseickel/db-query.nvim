--[[
Calls into vim-dadbod and vim-dadbod-completion, both optional.

- `resolve` expands a written url into the one a client is given.
- `refetch` points vim-dadbod-completion at a buffer's new `b:db`.
]]

local M = {}

--- Resolves `url` through vim-dadbod, which expands `$VAR` and follows variable
--- references. Returns the url unchanged when dadbod is not installed.
---
--- Returns nil for a nil or empty `url`, meaning the caller has to ask for a
--- connection. dadbod would resolve an empty url to `w:db`, `t:db`, `g:db`, or
--- `$DATABASE_URL`, which runs a buffer whose modeline connection failed
--- against a database the modeline never named.
---@param url string|nil
---@return string|nil
function M.resolve(url)
  if url == nil or url == "" then
    return nil
  end
  local ok, resolved = pcall(vim.fn["db#resolve"], url)
  if ok and resolved ~= "" then
    return resolved
  end
  return url
end

--- Loads the tables for `buf`'s `b:db` into vim-dadbod-completion. Does nothing
--- when that plugin is not installed, and warns when it fails to load them.
---
--- vim-dadbod-completion records a buffer's database once, at `FileType` or the
--- first completion, and keeps it, so a `b:db` set later needs this. Its `fetch`
--- reads `b:db` from the current buffer rather than the one it is given, so it
--- runs with `buf` current.
---@param buf integer
function M.refetch(buf)
  vim.api.nvim_buf_call(buf, function()
    local ok, err = pcall(vim.fn["vim_dadbod_completion#fetch"], buf)
    if not ok and not tostring(err):find("E117", 1, true) then
      vim.notify(
        "db-query: vim-dadbod-completion could not load the tables: " .. tostring(err),
        vim.log.levels.WARN
      )
    end
  end)
end

return M
