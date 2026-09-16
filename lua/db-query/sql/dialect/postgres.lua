--[[
Postgres sql as the server reads it, with no client commands. The sqlite and
duckdb dialects derive from it, changing only the parameter forms.
]]

local dialect = require("db-query.sql.dialect")
local standard = require("db-query.sql.dialect.standard")

local set = dialect.set

return dialect.derive(standard, {
  name = "postgres",
  signatures = vim.tbl_extend("force", standard.signatures, {
    greatest = { label = "greatest(value, ...)", parameters = { "value" }, variadic = true },
    least = { label = "least(value, ...)", parameters = { "value" }, variadic = true },
  }),
  keywords = vim.tbl_extend("force", standard.keywords, {
    start = vim.tbl_extend("force", standard.keywords.start, set("merge comment copy import truncate explain")),
    with = vim.tbl_extend("force", standard.keywords.with, set("materialized not")),
    select = vim.tbl_extend("force", standard.keywords.select, set("returning")),
    from = vim.tbl_extend("force", standard.keywords.from, set("returning tablesample")),
    where = vim.tbl_extend("force", standard.keywords.where, set("returning")),
    order_by = vim.tbl_extend("force", standard.keywords.order_by, set("nulls first last using")),
    insert_target = vim.tbl_extend("force", standard.keywords.insert_target, set("overriding")),
    delete_target = vim.tbl_extend("force", standard.keywords.delete_target, set("returning")),
    merge_when = vim.tbl_extend("force", standard.keywords.merge_when, set("by source target do nothing")),
    conflict = set("do"),
    conflict_update = set("set"),
    values = vim.tbl_extend("force", standard.keywords.values, set("conflict do nothing update returning")),
    set = vim.tbl_extend("force", standard.keywords.set, set("from returning")),
    expression = vim.tbl_extend("force", standard.keywords.expression, set("array interval")),
    operator = vim.tbl_extend("force", standard.keywords.operator, set("ilike collate")),
  }),
  lex = {
    escapeStrings = true,
    nestedComments = true,
    dollarQuotes = true,
    parameters = { "^%$%d+" },
    casts = true,
  },
  reserved = set([[
    returning ilike tablesample repeatable ordinality do conflict nothing materialized atomic returns
    language copy loop merge matched nulls first last
  ]]),
  queries = set("merge"),
  definitions = set("import"),
  beforeRelation = set("merge"),
  clauses = {
    { word = "perform", clause = "select" },
    { word = "returning", clause = "returning" },
    { word = "into", after = set("merge"), clause = "merge_target" },
    { word = "update", after = set("do then"), clause = "conflict_update" },
    { word = "set", within = set("conflict_update"), clause = "set" },
    { word = "values", within = set("merge_when"), clause = "values" },
    { word = "using", within = set("merge_target"), clause = "from" },
    { word = "conflict", after = set("on"), clause = "conflict" },
    {
      word = "when",
      within = set("from set values merge_when"),
      clause = "merge_when",
      test = function(state)
        return state.statement == "merge"
      end,
    },
  },
  fromSuffixes = {
    { "tablesample", dialect.ANY, dialect.GROUP },
    { "repeatable", dialect.GROUP },
    { "with", "ordinality" },
  },
  blocks = { { "begin", "atomic" } },
})
