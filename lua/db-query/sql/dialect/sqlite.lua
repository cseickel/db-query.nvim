--[[
SQLite sql: postgres's lexing with sqlite's parameters (`?`, `?1`, `:name`,
`@name`, `$name`), and fewer keywords and grammar functions.
]]

local dialect = require("db-query.sql.dialect")
local postgres = require("db-query.sql.dialect.postgres")
local standard = require("db-query.sql.dialect.standard")

local keywords = dialect.dropEverywhere(postgres.keywords, "fetch")

return dialect.derive(postgres, {
  name = "sqlite",
  folds = "none",
  -- sqlite has none of the other grammar forms postgres reads.
  signatures = {
    coalesce = standard.signatures.coalesce,
    nullif = standard.signatures.nullif,
    cast = standard.signatures.cast,
  },
  keywords = vim.tbl_extend("force", keywords, {
    start = dialect.without(keywords.start, "merge comment copy import truncate"),
    from = dialect.without(keywords.from, "for lateral tablesample"),
    fetch = {},
    merge_target = {},
    merge_when = {},
    expression = dialect.without(keywords.expression, "array interval"),
    operator = dialect.with(dialect.without(keywords.operator, "ilike similar"), "glob regexp match"),
    quantifier = {},
    call = dialect.without(keywords.call, "within"),
  }),
  lex = {
    parameters = { "^%?%d*", "^[:@$][%a_][%w_]*" },
  },
  inserts = { default = false },
})
