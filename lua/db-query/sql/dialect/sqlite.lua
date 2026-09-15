--[[
SQLite sql, read by the postgres rules plus sqlite's parameters: `?`, `?1`,
`:name`, `@name`, and `$name`.
]]

local dialect = require("db-query.sql.dialect")
local postgres = require("db-query.sql.dialect.postgres")

return dialect.derive(postgres, {
  name = "sqlite",
  lex = {
    parameters = { "^%?%d*", "^[:@$][%a_][%w_]*" },
  },
})
