--[[
Running statements through the mysql and mariadb clients.

The binary run is the whole difference between the two. MariaDB ships
`mariadb` and symlinks `mysql` to it, so the two schemes are what reaches the
right one on a machine holding both. MySQL 8 removed options MariaDB still
takes, `--ssl-verify-server-cert` among them.
]]

local rows = require("db-query.catalog.rows")
local sql = require("db-query.sql")
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

local SEARCH_PATH = [[select json_object('schema', database())]]

local RELATIONS = [[
select json_object(
  'schema', t.table_schema, 'name', t.table_name, 'kind', t.table_type, 'comment', t.table_comment,
  'column', c.column_name, 'type', c.column_type, 'nullable', c.is_nullable, 'default', c.column_default,
  'extra', c.extra, 'columnComment', c.column_comment)
from information_schema.tables t
left join information_schema.columns c on c.table_schema = t.table_schema and c.table_name = t.table_name
order by t.table_schema, t.table_name, c.ordinal_position]]

-- Only stored routines are here. The server's own functions are in no table.
local ROUTINES = [[
select json_object(
  'schema', routine_schema, 'specific', specific_name, 'name', routine_name, 'kind', routine_type,
  'result', dtd_identifier, 'comment', routine_comment)
from information_schema.routines
where routine_type in ('FUNCTION', 'PROCEDURE')]]

-- Position 0 is a function's result, which `routines` already gives. A
-- function and a procedure may share a name, and with it a specific name.
local PARAMETERS = [[
select json_object(
  'schema', specific_schema, 'specific', specific_name, 'kind', routine_type, 'name', parameter_name,
  'mode', parameter_mode, 'type', dtd_identifier)
from information_schema.parameters
where ordinal_position > 0
order by specific_schema, specific_name, ordinal_position]]

--- Returns a column's default. MariaDB writes a column without one as the
--- text NULL.
---@param default string|nil
---@return string|nil
local function columnDefault(default)
  return default ~= "NULL" and default or nil
end

--- Returns how a generated column is filled, from `extra`, which both servers
--- mark `VIRTUAL GENERATED` or `STORED GENERATED`. MySQL also writes
--- `DEFAULT_GENERATED` for a column whose default is an expression.
---@param extra string
---@return "stored"|"virtual"|nil
local function generated(extra)
  if extra:find("STORED GENERATED", 1, true) then
    return "stored"
  end
  if extra:find("VIRTUAL GENERATED", 1, true) then
    return "virtual"
  end
  return nil
end

---@param row table
---@return string
local function routineKey(row)
  return row.schema .. "." .. row.kind .. "." .. row.specific
end

---@param request dbquery.CatalogRequest
---@param done fun(catalog: dbquery.Catalog|nil, err: string|nil)
local function catalog(request, done)
  rows.collect(request, {
    searchPath = SEARCH_PATH,
    relations = RELATIONS,
    routines = ROUTINES,
    parameters = PARAMETERS,
  }, function(found, err)
    if not found then
      return done(nil, err)
    end

    local args = {}
    for _, row in ipairs(found.parameters) do
      local key = routineKey(row)
      args[key] = args[key] or {}
      table.insert(args[key], {
        name = row.name,
        type = row.type,
        mode = row.mode and row.mode:lower() or "in",
        default = false,
      })
    end

    done({
      searchPath = found.searchPath[1].schema and { { schema = found.searchPath[1].schema } } or {},
      relations = rows.relations(found.relations, function(row)
        local view = row.kind == "VIEW" or row.kind == "SYSTEM VIEW"
        return {
          schema = row.schema,
          name = row.name,
          kind = view and "view" or "table",
          -- mysql gives every view the comment VIEW.
          comment = row.comment ~= "VIEW" and rows.text(row.comment) or nil,
          columns = {},
        }
      end, function(row)
        if not row.column then
          return nil
        end
        local extra = row.extra or ""
        return {
          name = row.column,
          type = row.type,
          nullable = row.nullable == "YES",
          default = columnDefault(row.default),
          generated = generated(extra),
          hidden = extra:find("INVISIBLE", 1, true) ~= nil,
          labels = rows.labels(row.type),
          comment = rows.text(row.columnComment),
        }
      end),
      functions = vim.tbl_map(function(row)
        return {
          schema = row.schema,
          name = row.name,
          kind = row.kind:lower(),
          args = args[routineKey(row)] or {},
          returnsSet = false,
          result = row.result,
          comment = rows.text(row.comment),
        }
      end, found.routines),
      types = {},
    })
  end)
end

---@param binary "mysql"|"mariadb"
---@return dbquery.Client
local function client(binary)
  local dialect = require("db-query.sql.dialect." .. binary)
  return {
    name = binary,
    catalog = catalog,
    rows = { query = true },
    delimited = "tsv",
    dialect = dialect,

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
      local statement = spec.statement
      if spec.readonly then
        statement = "start transaction read only;\n" .. sql.stripTerminator(dialect, statement) .. "\n;\nrollback;\n"
      end
      -- The statement goes on stdin, where the client reads it as a script
      -- and acts on a `delimiter` line. mysql has no way to file rows itself,
      -- so the shell catches them.
      return { argv = argv, env = connects.env, stdin = statement, stdout = spec.path }
    end,
  }
end

return {
  mysql = client("mysql"),
  mariadb = client("mariadb"),
}
