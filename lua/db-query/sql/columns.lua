--[[
The names postgres gives the output columns of a select, which is what a
subquery or CTE offers as columns when it lists no names of its own.
]]

local lex = require("db-query.sql.lex")
local syntax = require("db-query.sql.syntax")

local M = {}

--- Words that continue a type name after its first word.
local TYPE_WORDS = { precision = true, varying = true, with = true, without = true, time = true, zone = true }

--- Clauses that follow a call without being its name, as in `count(*) filter (...)`.
local CALL_SUFFIXES = { filter = true, over = true }

--- Returns the index of the last item of the expression in `entry`, skipping
--- a `::type` cast and returning the alias after it, if any, through `alias`.
---@param entry dbquery.Token[]
---@return integer last
---@return dbquery.Token|nil alias
local function expressionEnd(entry)
  local last = #entry
  if lex.isWord(entry[last - 1], "as") and lex.isIdentifier(entry[last]) then
    return last - 2, entry[last]
  end

  for index = #entry, 1, -1 do
    if entry[index].kind == "cast" then
      local at = index + 1
      if lex.isIdentifier(entry[at]) then
        at = at + 1
      end
      while entry[at] and (syntax.isGroup(entry[at]) or (entry[at].kind == "word" and TYPE_WORDS[entry[at].lower])) do
        at = at + 1
      end
      if at == #entry and syntax.isName(entry[at]) then
        return index - 1, entry[at]
      end
      return index - 1, nil
    end
  end

  local previous = entry[last - 1]
  local implicit = last >= 2 and syntax.isName(entry[last]) and previous.kind ~= "." and previous.kind ~= "operator"
    and not lex.isWord(previous, "over")
  if implicit then
    return last - 1, entry[last]
  end
  return last, nil
end

--- Returns the name postgres gives the output column `entry`, or nil when it
--- cannot be told from the text.
---@param entry dbquery.Token[]
---@return string|nil
local function outputName(entry)
  local last, alias = expressionEnd(entry)
  if alias then
    return alias.text
  end

  -- `count(*) filter (where ...) over (...)` is named after the call.
  while last >= 2 do
    local item, before = entry[last], entry[last - 1]
    if syntax.isGroup(item) and before.kind == "word" and CALL_SUFFIXES[before.lower] then
      last = last - 2
    elseif lex.isIdentifier(item) and lex.isWord(before, "over") then
      last = last - 2
    elseif syntax.isGroup(item) and lex.isWord(before, "group") and lex.isWord(entry[last - 2], "within") then
      last = last - 3
    else
      break
    end
  end

  local item = entry[last]
  if not item then
    return nil
  end
  if item.kind == "operator" and item.text == "*" then
    return "*"
  end
  if lex.isWord(item, "end") then
    return "case"
  end
  if syntax.isGroup(item) and lex.isIdentifier(entry[last - 1]) then
    return entry[last - 1].text
  end
  if lex.isIdentifier(item) then
    return item.text
  end
  return nil
end

--- Returns the output column names of a select, or of the returning list of a
--- write. `*` stands for every column of the relations it reads.
---@param group dbquery.Group
---@return string[]
function M.outputs(group)
  local clauses, blocks = syntax.clauses(group.items)
  local names, entry = {}, {}
  local function close()
    local name = outputName(entry)
    if name then
      names[#names + 1] = name
    end
    entry = {}
  end
  for index, item in ipairs(group.items) do
    local listed = clauses[index] == "select" or clauses[index] == "returning"
    local keyword = lex.isWord(item, "select") or lex.isWord(item, "distinct") or lex.isWord(item, "returning")
    if blocks[index] == 1 and listed and not keyword then
      if item.kind == "," then
        close()
      else
        entry[#entry + 1] = item
      end
    end
  end
  close()
  return names
end

return M
