--[[
DuckDB sql, read by the postgres rules plus duckdb's parameters: `$1`, `?`,
and `$name`.
]]

local dialect = require("db-query.sql.dialect")
local postgres = require("db-query.sql.dialect.postgres")

return dialect.derive(postgres, {
  name = "duckdb",
  folds = "none",
  lex = {
    -- `$name` is a parameter only when no `$` follows, which would make it a dollar quote.
    parameters = { "^%$%d+", "^%?%d*", "^%$[%a_][%w_]*%f[^%w_$]" },
  },
})
