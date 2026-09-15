--[[
SQLite sql, read by the postgres rules plus sqlite's parameters: `?`, `?1`,
`:name`, `@name`, and `$name`.
]]

local dialect = require("db-query.sql.dialect")
local postgres = require("db-query.sql.dialect.postgres")
local standard = require("db-query.sql.dialect.standard")

return dialect.derive(postgres, {
  name = "sqlite",
  folds = "none",
  -- sqlite has none of the other grammar forms postgres reads.
  signatures = {
    coalesce = standard.signatures.coalesce,
    nullif = standard.signatures.nullif,
    cast = standard.signatures.cast,
  },
  lex = {
    parameters = { "^%?%d*", "^[:@$][%a_][%w_]*" },
  },
})
