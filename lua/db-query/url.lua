--[[
URL parsing for dadbod connection strings.

All functions decode percent-escapes from dadbod's canonicalization.
]]

local M = {}

---@param url string
---@return string
function M.scheme(url)
  return (url:match("^(%a[%w+.-]*):") or ""):lower()
end

--- Decodes percent-escapes.
---@param text string
---@return string
function M.decoded(text)
  return (text:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Returns the file path from a `scheme:path` url, or empty for in-memory.
---@param url string
---@return string
function M.filePath(url)
  local path = url:gsub("^%a[%w+.-]*:", ""):gsub("^//", "")
  if path == "" then
    return path
  end
  return vim.fn.fnamemodify(M.decoded(path), ":p")
end

--- Returns `url` with the password removed, and the password separately.
--- Splits on the last `@` to handle passwords containing `@`.
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
