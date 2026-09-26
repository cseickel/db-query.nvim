--[[
DuckDB sql: postgres's lexing with duckdb's parameters (`$1`, `?`, `$name`),
and duckdb's own keywords.
]]

local dialect = require("db-query.sql.dialect")
local postgres = require("db-query.sql.dialect.postgres")

local with, without = dialect.with, dialect.without

return dialect.derive(postgres, {
  name = "duckdb",
  folds = "none",
  keywords = {
    -- duckdb reads `from tbl select ...`, so a statement may open with `from`.
    start = with(without(postgres.keywords.start, "merge import"), "from"),
    select = with(postgres.keywords.select, "qualify exclude replace"),
    from = with(without(postgres.keywords.from, "for"), "qualify asof positional"),
    where = with(postgres.keywords.where, "qualify"),
    group_by = with(postgres.keywords.group_by, "qualify"),
    having = with(postgres.keywords.having, "qualify"),
    merge_target = {},
    merge_when = {},
    expression = with(postgres.keywords.expression, "struct map list"),
  },
  lex = {
    -- `$name` is a parameter only when no `$` follows, which would make it a dollar quote.
    parameters = { "^%$%d+", "^%?%d*", "^%$[%a_][%w_]*%f[^%w_$]" },
  },
  inserts = { default = true, uuid = "uuid()", array = "[]" },
})
