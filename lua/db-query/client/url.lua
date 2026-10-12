--[[
Parses dadbod connection urls.
]]

local M = {}

---@param url string
---@return string
function M.scheme(url)
  return (url:match("^(%a[%w+.-]*):") or ""):lower()
end

--- Decodes percent-escapes.
---@param encoded string
---@return string
function M.decoded(encoded)
  return (encoded:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

--- Returns the file path from a `scheme:path` url, or empty for in-memory,
--- which the url writes as no path or as `:memory:`.
---@param url string
---@return string
function M.filePath(url)
  local path = url:gsub("^%a[%w+.-]*:", ""):gsub("^//", "")
  if path == "" or path == ":memory:" then
    return ""
  end
  return vim.fn.fnamemodify(M.decoded(path), ":p")
end

--- Splits the query string off `url`, returning what came before it as written
--- and the parameters, decoded, in the order they were written.
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
  local withoutFragment = url:gsub("#.*$", "")
  local base, query = withoutFragment:match("^([^?]*)%?(.*)$")
  if not base then
    return withoutFragment, {}
  end

  local params = {}
  for param in query:gmatch("[^&;]+") do
    local key, value = param:match("^([^=]+)=(.*)$")
    if key then
      table.insert(params, { key = key, value = M.decoded((value:gsub("%+", " "))) })
    elseif not param:find("=", 1, true) then
      table.insert(params, { key = param, value = "1" })
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

  local kept, password = {}, nil
  for param in query:gmatch("[^&]+") do
    local key, value = param:match("^([^=]*)=(.*)$")
    if key and M.decoded(key) == "password" then
      password = M.decoded(value)
    else
      table.insert(kept, param)
    end
  end

  if not password then
    return url, nil
  end
  if #kept == 0 then
    return head, password
  end
  return head .. "?" .. table.concat(kept, "&"), password
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

--- Returns `url` with the password removed, and the password decoded. The
--- rest of the url stays as written, because the client parses it.
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
