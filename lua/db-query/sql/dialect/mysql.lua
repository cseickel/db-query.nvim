--[[
MySQL sql: backslash escapes in `'` and `"` strings, backtick identifiers, `#`
comments, `@variables`, and the insert, replace, and join forms mysql adds.
]]

local dialect = require("db-query.sql.dialect")
local standard = require("db-query.sql.dialect.standard")

local set = dialect.set

---@param state dbquery.ClauseState
---@return boolean
local function atStart(state)
  return state.clause == "start"
end

local HINT = set("use force ignore")
local KEY = set("index key")

--- Returns the delimiter a `delimiter` command sets: its argument, quoted or up
--- to whitespace. Returns nil for any other command.
---@param text string
---@return string|nil
local function delimiter(text)
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
end

--- The client's own commands: `\g` and `\G`, and `delimiter`, which the client
--- reads only at the start of a line and in any letter case. Each of them sends
--- the statement typed before it.
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
  delimiter = delimiter,
}

return dialect.derive(standard, {
  name = "mysql",
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
    { HINT, KEY, dialect.GROUP },
    { HINT, KEY, "for", "join", dialect.GROUP },
    { HINT, KEY, "for", set("order group"), "by", dialect.GROUP },
  },
})
