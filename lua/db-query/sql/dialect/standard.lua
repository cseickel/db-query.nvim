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
    -- `for update` and `for no key update` lock the rows a select reads.
    test = function(state)
      return state.after ~= "for" and state.after ~= "key"
    end,
  },
  { word = "set", within = set("update_target"), clause = "set" },
  { word = "values", within = set("insert_target start with setop"), clause = "values" },
  { word = "using", within = set("delete_target"), clause = "from" },
}

-- The clauses a query may go on with, each naming those that may follow it.
local SETOP = "union intersect except"
local AFTER_ORDER = "limit offset fetch " .. SETOP
local AFTER_WINDOW = "order " .. AFTER_ORDER
local AFTER_HAVING = "window " .. AFTER_WINDOW
local AFTER_GROUP = "having " .. AFTER_HAVING
local AFTER_WHERE = "group " .. AFTER_GROUP
local AFTER_FROM = "where " .. AFTER_WHERE

---@type dbquery.Keywords
local KEYWORDS = {
  start = set("select insert update delete with values table create alter drop begin"),
  with = set("recursive as"),
  setop = set("all distinct select"),
  select = set("as from " .. AFTER_FROM),
  from = set("as join inner left right full outer cross natural lateral on using for " .. AFTER_FROM),
  where = set(AFTER_WHERE),
  group_by = set(AFTER_GROUP),
  having = set(AFTER_HAVING),
  window = set(AFTER_WINDOW),
  order_by = set("asc desc " .. AFTER_ORDER),
  partition_by = set("order range rows groups"),
  limit = set("offset fetch " .. SETOP),
  offset = set("limit fetch " .. SETOP),
  fetch = set(SETOP),
  insert_target = set("values select default"),
  update_target = set("set"),
  delete_target = set("using where"),
  merge_target = set("using on when"),
  merge_when = set("when matched not then insert update delete values set"),
  values = set("on " .. SETOP),
  set = set("where"),
  expression = set("case cast not null true false exists"),
  operator = set("and or not is in like similar between"),
  quantifier = set("all any some"),
  projection = set("all distinct"),
  case = set("when then else end"),
  call = set("over filter within"),
  closes = set("null true false end asc desc first last"),
}

---@type table<string, dbquery.GrammarSignature>
local SIGNATURES = {
  coalesce = { label = "coalesce(value, ...)", parameters = { "value" }, variadic = true },
  nullif = { label = "nullif(value1, value2)", parameters = { "value1", "value2" }, variadic = false },
  cast = { label = "cast(value as type)", parameters = {}, variadic = false },
  extract = { label = "extract(field from source)", parameters = {}, variadic = false },
  substring = { label = "substring(string from start for count)", parameters = {}, variadic = false },
  trim = { label = "trim([leading | trailing | both] [characters] from string)", parameters = {}, variadic = false },
  position = { label = "position(substring in string)", parameters = {}, variadic = false },
  overlay = { label = "overlay(string placing replacement from start [for count])", parameters = {}, variadic = false },
}

---@type dbquery.Dialect
return {
  name = "standard",
  folds = "lower",
  signatures = SIGNATURES,
  keywords = KEYWORDS,
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
  definitions = set("create alter drop comment"),
  clauses = CLAUSES,
  joins = set("join inner left right full cross natural"),
  beforeRelation = set("from outer lateral only into update delete using insert"),
  callable = set("left right any some exists"),
  fromSuffixes = {},
  blocks = {},
}
