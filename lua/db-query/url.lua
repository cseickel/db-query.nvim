--[[
Taking a dadbod connection url apart.

What is pulled out of a url is handed to a client as itself rather than as part
of one, so everything here decodes the percent escapes dadbod's
canonicalization put in.
]]

local M = {}

---@param url string A dadbod connection url.
---@return string
function M.scheme(url)
  return (url:match("^(%a[%w+.-]*):") or ""):lower()
end

--- `text` with its percent escapes turned back into the characters they stand
--- for. A url that has been through vim-dadbod's canonicalization carries a
--- space as `%20`.
---@param text string
---@return string
function M.decoded(text)
  return (text:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- The file a `scheme:path` url names, empty for an in-memory database.
---
--- Made absolute with `fnamemodify` rather than `expand`, which would read a
--- decoded `%` as the current file name.
---@param url string
---@return string
function M.filePath(url)
  local path = url:gsub("^%a[%w+.-]*:", ""):gsub("^//", "")
  if path == "" then
    return path
  end
  return vim.fn.fnamemodify(M.decoded(path), ":p")
end

--- `url` with the password taken out of it, and that password. Both unchanged
--- when the url names none.
---
--- A command line is readable by every process on the machine, so the password
--- reaches the client through its environment instead.
---
--- The authority is cut at the last `@` it holds rather than the first, so a
--- password with an unencoded `@` in it splits where the user meant. What is
--- handed to the client afterwards has no password left in it, so the url it
--- parses is unambiguous either way.
---@param url string
---@return string url
---@return string|nil password
function M.withoutPassword(url)
  local prefix, authority, rest = url:match("^(%a[%w+.-]*://)([^/?#]*)(.*)$")
  if not authority then
    return url, nil
  end

  local credentials, host = authority:match("^(.*)@([^@]*)$")
  if not credentials then
    return url, nil
  end

  local user, password = credentials:match("^([^:]*):(.*)$")
  if not password or password == "" then
    return url, nil
  end
  return prefix .. user .. "@" .. host .. rest, M.decoded(password)
end

return M
