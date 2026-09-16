--[[
DuckDB sql, read by the postgres rules plus duckdb's parameters: `$1`, `?`,
and `$name`.
]]

local dialect = require("db-query.sql.dialect")
local postgres = require("db-query.sql.dialect.postgres")

return dialect.derive(postgres, {
  name = "duckdb",
  folds = "none",
  keywords = vim.tbl_extend("force", postgres.keywords, {
    -- duckdb reads `from tbl select ...`, so a statement may open with `from`.
    start = vim.tbl_extend("force", dialect.without(postgres.keywords.start, "merge import"), dialect.set("from")),
    select = vim.tbl_extend("force", postgres.keywords.select, dialect.set("qualify exclude replace")),
    from = vim.tbl_extend("force", dialect.without(postgres.keywords.from, "for"), dialect.set("qualify asof positional")),
    where = vim.tbl_extend("force", postgres.keywords.where, dialect.set("qualify")),
    group_by = vim.tbl_extend("force", postgres.keywords.group_by, dialect.set("qualify")),
    having = vim.tbl_extend("force", postgres.keywords.having, dialect.set("qualify")),
    merge_target = {},
    merge_when = {},
    expression = vim.tbl_extend("force", postgres.keywords.expression, dialect.set("struct map list")),
  }),
  lex = {
    -- `$name` is a parameter only when no `$` follows, which would make it a dollar quote.
    parameters = { "^%$%d+", "^%?%d*", "^%$[%a_][%w_]*%f[^%w_$]" },
  },
})
