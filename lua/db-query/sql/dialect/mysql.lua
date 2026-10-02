--[[
Defines mysql sql as the mysql client reads it.
]]

local dialect = require("db-query.sql.dialect")
local standard = require("db-query.sql.dialect.standard")

local set, with, without = dialect.set, dialect.with, dialect.without

---@param state dbquery.ClauseState
---@return boolean
local function atStart(state)
  return state.clause == "start"
end

local INDEX_HINT = set("use force ignore")
local INDEX_WORD = set("index key")

--- Reads the client's own commands, `\g`, `\G`, and `delimiter`. The client
--- reads `delimiter` only at the start of a line, in any letter case. Each
--- command sends the statement typed before it.
---@type dbquery.Commands
local COMMANDS = {
  at = function(text, index, lineStart)
    if text:match("^\\[gG]", index) then
      return index + 1
    end
    if lineStart and text:sub(index, index + 9):lower():match("^delimiter%s") then
      return text:find("\n", index, true) or #text
    end
    return nil
  end,
  sends = function()
    return true
  end,
  -- A `delimiter` command sets its argument, quoted or up to whitespace.
  delimiter = function(text)
    if not text:sub(1, 10):lower():match("^delimiter%s") then
      return nil
    end
    local rest = text:match("^%a+%s+(.-)%s*$")
    if rest == "" then
      return nil
    end
    local quote = rest:sub(1, 1)
    if quote == "'" or quote == '"' or quote == "`" then
      return rest:match("^" .. quote .. "(.-)" .. quote)
    end
    return rest:match("^%S+")
  end,
}

local keywords = dialect.dropEverywhere(standard.keywords, "fetch")

return dialect.derive(standard, {
  name = "mysql",
  folds = "none",
  keywords = vim.tbl_extend("force", keywords, {
    start = with(keywords.start, "replace truncate explain rename"),
    from = with(without(keywords.from, "full outer"), "straight_join use force ignore index"),
    fetch = {},
    insert_target = with(keywords.insert_target, "set"),
    merge_when = {},
    merge_target = {},
    values = with(keywords.values, "duplicate key update"),
    operator = with(without(keywords.operator, "similar"), "regexp rlike div xor"),
    call = without(keywords.call, "within"),
  }),
  commands = COMMANDS,
  lex = {
    strings = { ["'"] = true, ['"'] = true },
    identifiers = { ["`"] = "`" },
    -- mysql reads `--` as a comment only when whitespace or the end of the text follows it.
    lineComments = { "^#", "^%-%-[%s%c]", "^%-%-$" },
    parameters = { "^@@?[%a_$][%w_$%.]*", "^%?" },
  },
  reserved = set([[
    straight_join ignore replace duplicate key use force low_priority high_priority delayed quick
    regexp rlike div
  ]]),
  queries = set("replace"),
  definitions = set("rename"),
  clauses = {
    -- `into` is optional after insert and replace, and modifiers may come first.
    { word = "insert", clause = "insert_target", test = atStart },
    { word = "replace", clause = "insert_target", test = atStart },
    { word = "from", clause = "delete_target", test = function(state)
      return atStart(state) and state.statement == "delete"
    end },
    { word = "set", within = set("insert_target"), clause = "set" },
    { word = "update", after = set("key"), clause = "set" },
  },
  joins = set("straight_join"),
  beforeRelation = set("replace ignore low_priority high_priority delayed quick"),
  callable = set("replace insert"),
  fromSuffixes = {
    { "partition", dialect.GROUP },
    { INDEX_HINT, INDEX_WORD, dialect.GROUP },
    { INDEX_HINT, INDEX_WORD, "for", "join", dialect.GROUP },
    { INDEX_HINT, INDEX_WORD, "for", set("order group"), "by", dialect.GROUP },
  },
  inserts = { default = true, uuid = "uuid()" },
})
