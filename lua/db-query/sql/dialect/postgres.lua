--[[
Postgres sql as the server reads it, with no client commands. The sqlite and
duckdb dialects derive from it, changing only the parameter forms.
]]

local dialect = require("db-query.sql.dialect")
local standard = require("db-query.sql.dialect.standard")

local set = dialect.set

return dialect.derive(standard, {
  name = "postgres",
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
