--[[
Defines postgres sql as the server reads it, without client commands.
]]

local dialect = require("db-query.sql.dialect")
local standard = require("db-query.sql.dialect.standard")

local set, with = dialect.set, dialect.with

return dialect.derive(standard, {
  name = "postgres",
  keywords = {
    start = with(standard.keywords.start, "merge comment copy import truncate explain"),
    with = with(standard.keywords.with, "materialized not"),
    select = with(standard.keywords.select, "returning"),
    from = with(standard.keywords.from, "returning tablesample"),
    where = with(standard.keywords.where, "returning"),
    order_by = with(standard.keywords.order_by, "nulls first last using"),
    insert_target = with(standard.keywords.insert_target, "overriding"),
    delete_target = with(standard.keywords.delete_target, "returning"),
    merge_when = with(standard.keywords.merge_when, "by source target do nothing"),
    conflict = set("do"),
    conflict_update = set("set"),
    values = with(standard.keywords.values, "conflict do nothing update returning"),
    set = with(standard.keywords.set, "from returning"),
    expression = with(standard.keywords.expression, "array interval"),
    operator = with(standard.keywords.operator, "ilike collate"),
  },
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
  inserts = { default = true, uuid = "gen_random_uuid()", array = "'{}'" },
})
