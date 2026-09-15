--[[
Running statements through the mysql and mariadb clients.

The binary run is the whole difference between the two. MariaDB ships
`mariadb` and symlinks `mysql` to it, so the two schemes are what reaches the
right one on a machine holding both. MySQL 8 removed options MariaDB still
takes, `--ssl-verify-server-cert` among them.
]]

local url = require("db-query.url")

--- Converts a mysql or mariadb url into command-line arguments and environment.
---
--- A query parameter becomes a `--key=value` option, as dadbod does, so
--- `?ssl-verify-server-cert=0` reaches the client as that flag. A `password`
--- parameter goes to the environment instead, because a command line is
--- readable by every process on the machine. It takes the place of the password
--- in the credentials, and `?password=` on its own means no password at all.
---@param connection string mysql://user:password@host:port/database?option=value
---@return { argv: string[], env: table<string, string>|nil }
local function arguments(connection)
  local base, params = url.query(connection)
  local rest = base:gsub("^%a[%w+.-]*://", "")
  local authority, path = rest:match("^([^/]*)(.*)$")
  -- Split on last @ to handle passwords containing @.
  local credentials, location = authority:match("^(.*)@([^@]*)$")
  if not credentials then
    credentials, location = "", authority
  end

  local user, password = credentials:match("^([^:]*):?(.*)$")
  local host, port = location:match("^([^:]*):?(.*)$")
  user, password, host = url.decoded(user), url.decoded(password), url.decoded(host)
  local database = url.decoded((path:gsub("^/", "")))

  local found = {}
  for _, param in ipairs(params) do
    -- The name is decoded only to recognize it, so `?%70assword=` cannot walk
    -- a password onto the command line. The flag keeps the name as written.
    if url.decoded(param.key) == "password" then
      password = param.value
    else
      table.insert(found, "--" .. param.key .. "=" .. param.value)
    end
  end

  local function add(flag, value)
    if value ~= "" then
      vim.list_extend(found, { flag, value })
    end
  end
  add("-h", host)
  add("-P", port)
  add("-u", user)
  if database ~= "" then
    table.insert(found, database)
  end

  return {
    argv = found,
    env = password ~= "" and { MYSQL_PWD = password } or nil,
  }
end

---@param binary "mysql"|"mariadb"
---@return dbquery.Client
local function client(binary)
  return {
    rows = { query = true },
    delimited = "tsv",
    dialect = require("db-query.sql.dialect." .. binary),

    command = function(spec)
      local connects = arguments(spec.connection)
      local argv = { binary }
      -- --batch prints tab-separated rows in place of the ascii table.
      if spec.format == "value" then
        vim.list_extend(argv, { "--batch", "--skip-column-names", "--raw" })
      elseif spec.format == "csv" and spec.path then
        table.insert(argv, "--batch")
      end
      vim.list_extend(argv, connects.argv)
      -- The statement goes on stdin, where the client reads it as a script
      -- and acts on a `delimiter` line. mysql has no way to file rows itself,
      -- so the shell catches them.
      return { argv = argv, env = connects.env, stdin = spec.statement, stdout = spec.path }
    end,
  }
end

return {
  mysql = client("mysql"),
  mariadb = client("mariadb"),
}
