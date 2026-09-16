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
  keywords = vim.tbl_extend("force", postgres.keywords, {
    start = dialect.without(postgres.keywords.start, "merge comment copy import truncate"),
    select = dialect.without(postgres.keywords.select, "fetch"),
    from = dialect.without(postgres.keywords.from, "for lateral tablesample fetch"),
    where = dialect.without(postgres.keywords.where, "fetch"),
    group_by = dialect.without(postgres.keywords.group_by, "fetch"),
    having = dialect.without(postgres.keywords.having, "fetch"),
    window = dialect.without(postgres.keywords.window, "fetch"),
    order_by = dialect.without(postgres.keywords.order_by, "fetch"),
    limit = dialect.without(postgres.keywords.limit, "fetch"),
    offset = dialect.without(postgres.keywords.offset, "fetch"),
    fetch = {},
    merge_target = {},
    merge_when = {},
    expression = dialect.without(postgres.keywords.expression, "array interval"),
    operator = vim.tbl_extend(
      "force",
      dialect.without(postgres.keywords.operator, "ilike similar"),
      dialect.set("glob regexp match")
    ),
    quantifier = {},
    call = dialect.without(postgres.keywords.call, "within"),
  }),
  lex = {
    parameters = { "^%?%d*", "^[:@$][%a_][%w_]*" },
  },
})
