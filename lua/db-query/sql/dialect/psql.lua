--[[
Postgres sql as psql reads it: backslash commands and `:name` variables, which
psql handles itself before the server sees the text.
]]

local dialect = require("db-query.sql.dialect")
local postgres = require("db-query.sql.dialect.postgres")

--- psql commands that send the query typed before them, as `;` does.
local SENDS = dialect.set("g gx gset gexec gdesc watch crosstabview")

return dialect.derive(postgres, {
  name = "psql",
  commands = {
    at = function(text, index)
      if text:sub(index, index) ~= "\\" then
        return nil
      end
      return text:find("\n", index, true) or #text
    end,
    variables = "^:['\"]?[%a_][%w_]*['\"]?",
    sends = function(text)
      return SENDS[text:lower():match("^\\(%a+)")] == true or text:match(";%s*$") ~= nil
    end,
  },
})
