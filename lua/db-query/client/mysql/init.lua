--[[
Builds the mysql and mariadb command lines that run a statement.
]]

local sql = require("db-query.sql")
local url = require("db-query.client.url")

--- Returns the command-line arguments and environment that connect to a mysql
--- or mariadb url.
---
--- A query parameter becomes a `--key=value` option, as dadbod does, so
--- `?ssl-verify-server-cert=0` reaches the client as that flag. A `password`
--- parameter goes to the environment instead, because a command line is
--- readable by every process on the machine. It takes the place of the password
--- in the credentials, and `?password=` on its own means no password at all.
---@param connection string mysql://user:password@host:port/database?option=value
---@return { argv: string[], env: table<string, string>|nil }
local function login(connection)
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

  local argv = {}
  for _, param in ipairs(params) do
    -- The name is decoded only to recognize it, so `?%70assword=` cannot walk
    -- a password onto the command line. The flag keeps the name as written.
    if url.decoded(param.key) == "password" then
      password = param.value
    else
      table.insert(argv, "--" .. param.key .. "=" .. param.value)
    end
  end

  for _, option in ipairs({ { "-h", host }, { "-P", port }, { "-u", user } }) do
    if option[2] ~= "" then
      vim.list_extend(argv, option)
    end
  end
  if database ~= "" then
    table.insert(argv, database)
  end

  return {
    argv = argv,
    env = password ~= "" and { MYSQL_PWD = password } or nil,
  }
end

--- Returns the client that runs `binary`. The mysql and mariadb schemes run
--- different binaries, because MariaDB installs `mysql` as a symlink to
--- `mariadb`, and MySQL 8 rejects flags MariaDB accepts, such as
--- `--ssl-verify-server-cert`.
---@param binary "mysql"|"mariadb"
---@return dbquery.Client
local function client(binary)
  local dialect = require("db-query.sql.dialect." .. binary)
  return {
    name = binary,
    catalog = require("db-query.client.mysql.catalog"),
    definition = require("db-query.client.mysql.definition"),
    references = require("db-query.client.mysql.references"),
    rowKinds = { query = true },
    csvExtension = "tsv",
    dialect = dialect,

    command = function(spec)
      local credentials = login(spec.connection)
      local argv = { binary }
      -- --batch prints tab-separated rows in place of the ascii table.
      if spec.format == "value" then
        vim.list_extend(argv, { "--batch", "--skip-column-names", "--raw" })
      elseif spec.format == "csv" and spec.path then
        table.insert(argv, "--batch")
      end
      vim.list_extend(argv, credentials.argv)
      local statement = spec.statement
      if spec.readonly then
        statement = "start transaction read only;\n" .. sql.stripTerminator(dialect, statement) .. "\n;\nrollback;\n"
      end
      -- The statement goes on stdin, where the client reads it as a script
      -- and acts on a `delimiter` line. mysql has no way to file rows itself,
      -- so the shell catches them.
      return { argv = argv, env = credentials.env, stdin = statement, stdout = spec.path }
    end,
  }
end

return {
  mysql = client("mysql"),
  mariadb = client("mariadb"),
}
