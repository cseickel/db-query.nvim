--[[
URL parsing for dadbod connection strings.

A value pulled out of a url comes back with its percent-escapes decoded, ready
for a command line. A url handed back is left exactly as it was written, minus
whatever was taken out of it, because the client is the one that parses it.
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

--- Splits the query string off `url`, returning what came before it and the
--- parameters in the order they were written.
---
--- These are dadbod's rules, and they hold for the clients that take parameters
--- as flags. A fragment goes with the query string, `&` and `;` both separate,
--- `+` in a value is a space, a parameter written without a value takes "1", and
--- a parameter with an empty name is dropped. psql is handed its url whole, so
--- libpq parses that one and none of this reaches it.
---@param url string
---@return string url
---@return { key: string, value: string }[] params
function M.query(url)
  local whole = url:gsub("#.*$", "")
  local base, query = whole:match("^([^?]*)%?(.*)$")
  if not base then
    return whole, {}
  end

  local params = {}
  for item in query:gmatch("[^&;]+") do
    local key, value = item:match("^([^=]+)=(.*)$")
    if key then
      table.insert(params, { key = key, value = M.decoded((value:gsub("%+", " "))) })
    elseif not item:find("=", 1, true) then
      table.insert(params, { key = item, value = "1" })
    end
  end
  return base, params
end

--- Returns `url` with its `password` parameter cut out, and that parameter's
--- value.
---
--- Every other parameter is left byte for byte, and the name and value are read
--- by libpq's rules, percent-escapes and nothing else, because psql is handed
--- this url whole and libpq is what parses it. libpq has no fragment and
--- separates only on `&`.
---@param url string
---@return string url
---@return string|nil password
local function withoutPasswordParam(url)
  local head, query = url:match("^([^?]*)%?(.*)$")
  if not query then
    return url, nil
  end

  local kept, found = {}, nil
  for item in query:gmatch("[^&]+") do
    local key, value = item:match("^([^=]*)=(.*)$")
    if key and M.decoded(key) == "password" then
      found = M.decoded(value)
    else
      table.insert(kept, item)
    end
  end

  if not found then
    return url, nil
  end
  if #kept == 0 then
    return head, found
  end
  return head .. "?" .. table.concat(kept, "&"), found
end

--- Returns `url` with the password in its credentials removed, and that
--- password. Splits on the last `@` to handle passwords containing `@`.
---@param url string
---@return string url
---@return string|nil password
local function withoutCredential(url)
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

--- Returns `url` with the password removed, and the password separately.
---
--- A password hides in two places, the credentials before the last `@` and a
--- `password` query parameter. Both come out of the url, because a command line
--- is readable by every process on the machine. The parameter is the one that
--- comes back, because it is the one libpq authenticates with, and `?password=`
--- on its own means no password at all.
---@param url string
---@return string url
---@return string|nil password
function M.withoutPassword(url)
  local stripped, param = withoutPasswordParam(url)
  local without, credential = withoutCredential(stripped)
  local password = param or credential
  return without, password ~= "" and password or nil
end

return M
