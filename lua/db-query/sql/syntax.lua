--[[
The shape of one statement, read from its tokens.

- `groups` nests the tokens by parentheses and brackets, closing a group left
  open before the cursor where the next clause starts.
- `clauses` labels each item of a group with the clause it belongs to, and
  numbers the union, intersect, and except blocks.
- The rest reads names, keywords, and argument positions off a group's items.
]]

local lex = require("db-query.sql.lex")

local M = {}

---@class dbquery.Group
---@field items dbquery.Token[] Tokens, with each nested group as a token of kind "group".
---@field parent dbquery.Group|nil
---@field index integer Position of this group among its parent's items, 0 for the statement itself.
---@field open "("|"["|nil

---@class dbquery.Token
---@field group dbquery.Group|nil The nested group, on a token of kind "group".

---@alias dbquery.Clause
---| "start" Before the first clause keyword.
---| "with" | "select" | "from" | "where" | "having" | "window" | "group_by" | "order_by" | "partition_by"
---| "limit" | "offset" | "fetch" | "returning" | "values" | "set"
---| "insert_target" | "update_target" | "delete_target" | "merge_target" The table a write names.
---| "conflict" | "conflict_update" | "merge_when"
---| "setop" Just after union, intersect, or except.

--- Words that are never a table alias.
local KEYWORDS = {}
for word in ([[
  select from where group by having window order limit offset fetch for returning set values using on
  join inner left right full outer cross natural lateral union intersect except all distinct as with
  recursive insert into update delete merge when matched then do conflict nothing and or not in is null
  like ilike similar between case else end exists any some table only tablesample repeatable ordinality
  partition over filter within create index references alter add column drop begin atomic returns
  language materialized copy desc asc nulls last first true false loop
]]):gmatch("%S+") do
  KEYWORDS[word] = true
end

--- Words that start a statement which returns or writes rows.
M.QUERY = { select = true, with = true, values = true, table = true, insert = true, update = true, delete = true, merge = true }

--- Clause keywords at which a group left open before the cursor is closed.
local CLOSES_CALL = {
  from = true, where = true, group = true, order = true, having = true, limit = true, offset = true,
  join = true, union = true, intersect = true, except = true, returning = true, window = true,
}

--- Returns true for a quoted identifier or a word that is not a keyword.
---@param token dbquery.Token|nil
---@return boolean
function M.isName(token)
  return token ~= nil and (token.kind == "quoted" or (token.kind == "word" and not KEYWORDS[token.lower]))
end

---@param token dbquery.Token|nil
---@return boolean
function M.isGroup(token)
  return token ~= nil and token.kind == "group"
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
--- where a clause keyword appears after the cursor. A group whose first word
--- starts a query stays open, because clause keywords belong inside it.
---@param statement dbquery.Token[]
---@return dbquery.Token[]
local function closeGroups(statement)
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
    if pastCursor and token.kind == "word" and CLOSES_CALL[token.lower] then
      local top = open[#open]
      while missing > 0 and top and top.beforeCursor and not top.query do
        repaired[#repaired + 1] = { kind = ")", first = token.first, last = token.first - 1, text = ")", lower = ")", open = false }
        open[#open] = nil
        missing = missing - 1
        top = open[#open]
      end
    end
    repaired[#repaired + 1] = token
    if token.kind == "(" then
      local next = statement[index + 1]
      open[#open + 1] = { beforeCursor = not pastCursor, query = next ~= nil and next.kind == "word" and M.QUERY[next.lower] == true }
    elseif token.kind == ")" then
      open[#open] = nil
    elseif token.kind == "cursor" then
      pastCursor = true
    end
  end
  return repaired
end

--- Nests `statement` by parentheses and brackets. Returns the statement as a
--- group, and the group and index holding the cursor token.
---@param statement dbquery.Token[] Code tokens of one statement, holding one cursor token.
---@return dbquery.Group root
---@return dbquery.Group cursorGroup
---@return integer cursorIndex
function M.groups(statement)
  local root = { items = {}, index = 0 }
  local group, cursorGroup, cursorIndex = root, root, 1
  for _, token in ipairs(closeGroups(statement)) do
    if token.kind == "(" or token.kind == "[" then
      local nested = { items = {}, parent = group, open = token.kind }
      group.items[#group.items + 1] = {
        kind = "group", first = token.first, last = token.last, text = token.text, lower = token.lower, open = false, group = nested,
      }
      nested.index = #group.items
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

--- Labels each item of `items` with its clause and its union block.
---@param items dbquery.Token[]
---@return dbquery.Clause[] clauses
---@return integer[] blocks
function M.clauses(items)
  local clauses, blocks = {}, {}
  local clause, block = "start", 1
  local merge = lex.isWord(items[1], "merge")
  for index, item in ipairs(items) do
    local word = item.kind == "word" and item.lower or nil
    local previous = items[index - 1]
    local after = previous and previous.kind == "word" and previous.lower or nil

    if word == "union" or word == "intersect" or word == "except" then
      block, clause = block + 1, "setop"
    elseif word == "with" and (clause == "start" or clause == "setop") then
      clause = "with"
    elseif word == "select" or word == "perform" then
      clause = "select"
    elseif word == "from" and after == "delete" then
      clause = "delete_target"
    elseif word == "from" and after ~= "distinct" and clause ~= "start" then
      clause = "from"
    elseif word == "where" then
      clause = "where"
    elseif word == "having" then
      clause = "having"
    elseif word == "window" then
      clause = "window"
    elseif word == "returning" then
      clause = "returning"
    elseif word == "limit" then
      clause = "limit"
    elseif word == "offset" then
      clause = "offset"
    elseif word == "fetch" then
      clause = "fetch"
    elseif word == "by" and after == "group" then
      clause = "group_by"
    elseif word == "by" and after == "order" then
      clause = "order_by"
    elseif word == "by" and after == "partition" then
      clause = "partition_by"
    elseif word == "into" and after == "insert" then
      clause = "insert_target"
    elseif word == "into" and after == "merge" then
      clause = "merge_target"
    elseif word == "update" and (after == "do" or after == "then") then
      clause = "conflict_update"
    elseif word == "update" and after ~= "for" then
      clause = "update_target"
    elseif word == "set" and (clause == "update_target" or clause == "conflict_update") then
      clause = "set"
    elseif word == "values" and (clause == "insert_target" or clause == "start" or clause == "with" or clause == "setop" or clause == "merge_when") then
      clause = "values"
    elseif word == "using" and (clause == "delete_target" or clause == "merge_target") then
      clause = "from"
    elseif word == "conflict" and after == "on" then
      clause = "conflict"
    elseif word == "when" and merge and (clause == "from" or clause == "set" or clause == "values" or clause == "merge_when") then
      clause = "merge_when"
    end
    clauses[index], blocks[index] = clause, block
  end
  return clauses, blocks
end

return M
