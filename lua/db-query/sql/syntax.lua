--[[
The shape of one statement, read from its tokens.

- `groups` nests the tokens by parentheses and brackets, closing a group left
  open before the cursor where the next clause starts.
- `clauses` labels each item of a group with the clause it belongs to, and
  numbers its query blocks: one per arm of a union, intersect, or except, and
  one per statement written with no `;` before it.
- The rest reads names, keywords, and argument positions off a group's items.
]]

local lex = require("db-query.sql.lex")

local M = {}

---@class dbquery.Group
---@field items dbquery.Token[] Tokens, with each nested group as a token of kind "group".
---@field parent dbquery.Group|nil
---@field index integer Position of this group among its parent's items, 0 for the statement itself.
---@field open "("|"["|nil
---@field dialect dbquery.Dialect

---@class dbquery.Token
---@field group dbquery.Group|nil The nested group, on a token of kind "group".

---@alias dbquery.Clause
---| "start" Before the first clause keyword.
---| "with" | "select" | "from" | "where" | "having" | "window" | "group_by" | "order_by" | "partition_by"
---| "limit" | "offset" | "fetch" | "returning" | "values" | "set"
---| "insert_target" | "update_target" | "delete_target" | "merge_target" The table a write names.
---| "conflict" | "conflict_update" | "merge_when"
---| "setop" Just after union, intersect, or except.

--- Clause keywords at which a group left open before the cursor is closed.
local CLOSES_CALL = {
  from = true, where = true, group = true, order = true, having = true, limit = true, offset = true,
  join = true, union = true, intersect = true, except = true, returning = true, window = true,
}

local SETOPS = { union = true, intersect = true, except = true }

--- Clauses a query may follow within one statement, such as the query an
--- insert reads its rows from. A query that starts anywhere else reads its own
--- relations, so it opens a block of its own.
local TAKES_QUERY = {
  start = true, setop = true, with = true, merge_when = true, conflict = true, conflict_update = true,
  insert_target = true, update_target = true, delete_target = true, merge_target = true,
}

--- Token kinds that leave an expression unfinished, so a query word after one
--- of them stands inside that expression rather than starting a statement, as
--- the `values` of mysql's `update a = values(a)` does.
local UNFINISHED = { operator = true, cast = true, [","] = true, ["."] = true }

--- Words that make the query word after them the tail of a phrase rather than
--- the head of a statement: `for update` and `for no key update`.
local PHRASE = { ["for"] = true, key = true }

--- Returns a token that stands for no text at `first`, such as the cursor.
---@param kind dbquery.TokenKind
---@param first integer
---@return dbquery.Token
function M.marker(kind, first)
  return { kind = kind, first = first, last = first - 1, text = "", lower = "", open = false, reserved = false }
end

--- Returns true for a quoted identifier or a word the dialect does not reserve.
---@param token dbquery.Token|nil
---@return boolean
function M.isName(token)
  return token ~= nil and (token.kind == "quoted" or (token.kind == "word" and not token.reserved))
end

---@param token dbquery.Token|nil
---@return boolean
function M.isGroup(token)
  return token ~= nil and token.kind == "group"
end

--- Returns true when `items[index]` calls a function, as mysql's `replace(`
--- does, rather than starting the clause its word names.
---@param dialect dbquery.Dialect
---@param items dbquery.Token[]
---@param index integer
---@return boolean
local function calls(dialect, items, index)
  local item, next = items[index], items[index + 1]
  local opens = next ~= nil and (next.kind == "group" or next.kind == "(")
  return item.kind == "word" and dialect.callable[item.lower] == true and opens
end

--- Returns true when `items[index]` starts a query in `dialect`.
---@param dialect dbquery.Dialect
---@param items dbquery.Token[]
---@param index integer
---@return boolean
local function queryAt(dialect, items, index)
  local item = items[index]
  return item ~= nil and item.kind == "word" and dialect.queries[item.lower] == true and not calls(dialect, items, index)
end

--- Returns true when `items[index]` starts a statement in `dialect`: a query,
--- or a definition such as `create table`.
---@param dialect dbquery.Dialect
---@param items dbquery.Token[]
---@param index integer
---@return boolean
local function statementAt(dialect, items, index)
  local item = items[index]
  if queryAt(dialect, items, index) then
    return true
  end
  return item ~= nil and item.kind == "word" and dialect.definitions[item.lower] == true
end

--- Returns true when `group` holds a query, going by its first word.
---@param group dbquery.Group
---@return boolean
function M.startsQuery(group)
  local index = 1
  while group.items[index] and group.items[index].kind == "cursor" do
    index = index + 1
  end
  return queryAt(group.dialect, group.items, index)
end

--- Returns the dotted name starting at `items[index]` and the index after it.
---@param items dbquery.Token[]
---@param index integer
---@return string|nil name
---@return integer after
function M.nameAt(items, index)
  if not lex.isIdentifier(items[index]) then
    return nil, index
  end
  local parts, at = { items[index].text }, index + 1
  while items[at] and items[at].kind == "." and lex.isIdentifier(items[at + 1]) do
    parts[#parts + 1] = items[at + 1].text
    at = at + 2
  end
  return table.concat(parts, "."), at
end

--- Returns the dotted name ending at `items[index]` and the index it starts at.
---@param items dbquery.Token[]
---@param index integer
---@return string|nil name
---@return integer first
function M.nameBefore(items, index)
  if not lex.isIdentifier(items[index]) then
    return nil, index
  end
  local parts, first = { items[index].text }, index
  while items[first - 1] and items[first - 1].kind == "." and lex.isIdentifier(items[first - 2]) do
    table.insert(parts, 1, items[first - 2].text)
    first = first - 2
  end
  return table.concat(parts, "."), first
end

--- Returns the first word of `group`, ignoring the cursor.
---@param group dbquery.Group
---@return string|nil
function M.firstWord(group)
  for _, item in ipairs(group.items) do
    if item.kind ~= "cursor" then
      return item.kind == "word" and item.lower or nil
    end
  end
  return nil
end

--- Returns which comma-separated position `items[index]` is in, counting from 1.
---@param items dbquery.Token[]
---@param index integer
---@return integer
function M.position(items, index)
  local position = 1
  for at = 1, index - 1 do
    if items[at].kind == "," then
      position = position + 1
    end
  end
  return position
end

--- Returns the first identifier of each comma-separated entry in `group`, which
--- names the columns of `(a, b)` and of `(a int, b text)` alike.
---@param group dbquery.Group
---@return string[]
function M.listNames(group)
  local names, fresh = {}, true
  for _, item in ipairs(group.items) do
    if item.kind == "," then
      fresh = true
    elseif fresh and lex.isIdentifier(item) then
      names[#names + 1] = item.text
      fresh = false
    end
  end
  return names
end

--- Closes groups the statement leaves open before the cursor, so text typed
--- after an unclosed call such as `coalesce(t.` is read as the clause it is.
---
--- Only as many groups are closed as the statement is short of `)`, and only
--- where a clause keyword appears after the cursor, or where a statement
--- starts after it in a group that holds none: a `(` written after a name is a
--- call's arguments or a column list, never a query. A group whose first word
--- starts a query stays open, because clause keywords belong inside it.
---@param dialect dbquery.Dialect
---@param statement dbquery.Token[]
---@return dbquery.Token[]
local function closeGroups(dialect, statement)
  local missing = 0
  for _, token in ipairs(statement) do
    if token.kind == "(" then
      missing = missing + 1
    elseif token.kind == ")" then
      missing = missing - 1
    end
  end
  if missing <= 0 then
    return statement
  end

  local repaired, open, pastCursor = {}, {}, false
  for index, token in ipairs(statement) do
    if pastCursor then
      local closes = token.kind == "word" and CLOSES_CALL[token.lower] == true
      local starts = statementAt(dialect, statement, index)
      local top = open[#open]
      while missing > 0 and top and top.beforeCursor and not top.query
        and (closes or (starts and not top.takesQuery)) do
        repaired[#repaired + 1] = M.marker(")", token.first)
        open[#open] = nil
        missing = missing - 1
        top = open[#open]
      end
    end
    repaired[#repaired + 1] = token
    if token.kind == "(" then
      open[#open + 1] = {
        beforeCursor = not pastCursor,
        query = queryAt(dialect, statement, index + 1),
        takesQuery = not M.isName(statement[index - 1]),
      }
    elseif token.kind == ")" then
      open[#open] = nil
    elseif token.kind == "cursor" then
      pastCursor = true
    end
  end
  return repaired
end

--- Nests `statement` by parentheses and brackets. Returns the statement as a
--- group, and the group and index holding the cursor token. Every group reads
--- by the rules of `dialect`.
---@param dialect dbquery.Dialect
---@param statement dbquery.Token[] Code tokens of one statement, holding one cursor token.
---@return dbquery.Group root
---@return dbquery.Group cursorGroup
---@return integer cursorIndex
function M.groups(dialect, statement)
  local root = { items = {}, index = 0, dialect = dialect }
  local group, cursorGroup, cursorIndex = root, root, 1
  for _, token in ipairs(closeGroups(dialect, statement)) do
    if token.kind == "(" or token.kind == "[" then
      local nested = { items = {}, parent = group, open = token.kind, index = #group.items + 1, dialect = dialect }
      local wrapper = M.marker("group", token.first)
      wrapper.last, wrapper.text, wrapper.lower, wrapper.group = token.last, token.text, token.lower, nested
      group.items[#group.items + 1] = wrapper
      group = nested
    elseif (token.kind == ")" or token.kind == "]") and group.parent then
      group = group.parent
    else
      group.items[#group.items + 1] = token
      if token.kind == "cursor" then
        cursorGroup, cursorIndex = group, #group.items
      end
    end
  end
  return root, cursorGroup, cursorIndex
end

---@param rule dbquery.ClauseRule
---@param word string
---@param state dbquery.ClauseState
---@return boolean
local function applies(rule, word, state)
  return rule.word == word
    and (rule.after == nil or (state.after ~= nil and rule.after[state.after] == true))
    and (rule.within == nil or rule.within[state.clause] == true)
    and (rule.test == nil or rule.test(state))
end

--- Returns true when `items[index]`, the word `with`, opens a with clause:
--- `with [recursive] name [(columns)] as`. A from clause ends in `with
--- ordinality`, where `with` opens nothing.
---@param items dbquery.Token[]
---@param index integer
---@return boolean
local function opensWith(items, index)
  local at = index + 1
  if lex.isWord(items[at], "recursive") then
    at = at + 1
  end
  if not M.isName(items[at]) then
    return false
  end
  at = at + 1
  if M.isGroup(items[at]) then
    at = at + 1
  end
  return lex.isWord(items[at], "as")
end

--- Returns true when the query word at `index` heads a statement of its own,
--- rather than naming a clause of the statement already being read.
---@param items dbquery.Token[]
---@param index integer
---@param rule dbquery.ClauseRule|nil The rule that labels this word here, if one does.
---@return boolean
local function opensStatement(items, index, rule)
  -- A rule that matches by the word before this one, as mysql's `update`
  -- after `key`, names a clause of the statement being read.
  if rule ~= nil and rule.after ~= nil then
    return false
  end
  local previous = items[index - 1]
  if previous ~= nil and (UNFINISHED[previous.kind] or PHRASE[previous.lower]) then
    return false
  end
  return items[index].lower ~= "with" or opensWith(items, index)
end

--- Labels each item of `group` with its clause and its query block.
---@param group dbquery.Group
---@return dbquery.Clause[] clauses
---@return integer[] blocks
function M.clauses(group)
  local items, rules = group.items, group.dialect.clauses
  local clauses, blocks = {}, {}
  local clause, block = "start", 1
  local statement = items[1] and items[1].kind == "word" and items[1].lower or nil
  for index, item in ipairs(items) do
    local previous = items[index - 1]
    if item.kind == "word" and SETOPS[item.lower] then
      block, clause = block + 1, "setop"
    elseif item.kind == "word" and not calls(group.dialect, items, index) then
      ---@type dbquery.ClauseState
      local state = { after = previous and previous.kind == "word" and previous.lower or nil, clause = clause, statement = statement }
      local matched = nil
      for _, rule in ipairs(rules) do
        if applies(rule, item.lower, state) then
          matched = rule
          break
        end
      end
      if group.dialect.queries[item.lower] and not TAKES_QUERY[clause] and opensStatement(items, index, matched) then
        block = block + 1
      end
      if matched then
        clause = matched.clause
      end
    end
    clauses[index], blocks[index] = clause, block
  end
  return clauses, blocks
end

return M
