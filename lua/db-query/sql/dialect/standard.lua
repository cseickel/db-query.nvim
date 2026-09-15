--[[
The sql every other dialect starts from: `'` strings with doubled quotes, `"`
identifiers, `--` and `/* */` comments, and the clauses of select, insert,
update, and delete.
]]

local dialect = require("db-query.sql.dialect")

local set = dialect.set

---@type dbquery.ClauseRule[]
local CLAUSES = {
  { word = "with", within = set("start setop"), clause = "with" },
  { word = "select", clause = "select" },
  { word = "from", after = set("delete"), clause = "delete_target" },
  {
    word = "from",
    clause = "from",
    test = function(state)
      return state.after ~= "distinct" and state.clause ~= "start"
    end,
  },
  { word = "where", clause = "where" },
  { word = "having", clause = "having" },
  { word = "window", clause = "window" },
  { word = "limit", clause = "limit" },
  { word = "offset", clause = "offset" },
  { word = "fetch", clause = "fetch" },
  { word = "by", after = set("group"), clause = "group_by" },
  { word = "by", after = set("order"), clause = "order_by" },
  { word = "by", after = set("partition"), clause = "partition_by" },
  { word = "into", after = set("insert"), clause = "insert_target" },
  {
    word = "update",
    clause = "update_target",
    test = function(state)
      return state.after ~= "for"
    end,
  },
  { word = "set", within = set("update_target"), clause = "set" },
  { word = "values", within = set("insert_target start with setop"), clause = "values" },
  { word = "using", within = set("delete_target"), clause = "from" },
}

---@type dbquery.Dialect
return {
  name = "standard",
  lex = {
    strings = { ["'"] = false },
    escapeStrings = false,
    identifiers = { ['"'] = '"' },
    lineComments = { "^%-%-" },
    nestedComments = false,
    dollarQuotes = false,
    parameters = {},
    casts = false,
  },
  reserved = set([[
    select from where group by having window order limit offset fetch for set values using on
    join inner left right full outer cross natural lateral union intersect except all distinct as with
    recursive insert into update delete when then and or not in is null like similar between case else
    end exists any some table only create index references alter add column drop begin true false
    desc asc over filter within partition
  ]]),
  queries = set("select with values table insert update delete"),
  clauses = CLAUSES,
  joins = set("join inner left right full cross natural"),
  beforeRelation = set("from outer lateral only into update delete using insert"),
  callable = set("left right any some exists"),
  fromSuffixes = {},
  blocks = {},
}
