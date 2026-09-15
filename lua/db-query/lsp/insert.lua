--[[
Completion items that write an insert's column list and values row.

An insert is always written with its column list, so a column dropped from it
is one deletion away, and a values row is only filled for a list that is
written. The database's own columns, identity and generated ones, and hidden
ones are left out.
]]

local names = require("db-query.lsp.names")

local M = {}

local Kind = vim.lsp.protocol.CompletionItemKind
local SNIPPET = vim.lsp.protocol.InsertTextFormat.Snippet

--- Returns `text` with the characters a snippet reads as syntax escaped.
---@param text string
---@return string
local function escaped(text)
  return (text:gsub("[\\$}]", "\\%0"))
end

--- Returns the placeholders of a values row for `columns`, each holding the
--- column's name and, when known, its type as a comment.
---@param columns { name: string, type: string|nil }[]
---@return string
local function placeholders(columns)
  local parts = {}
  for index, column in ipairs(columns) do
    local text = column.name
    if column.type and column.type ~= "" then
      -- A type such as enum('a', 'b') could otherwise close the comment early.
      text = text .. " /* " .. column.type:gsub("/%*", "/ *"):gsub("%*/", "* /") .. " */"
    end
    parts[index] = "${" .. index .. ":" .. escaped(text) .. "}"
  end
  return table.concat(parts, ", ")
end

---@param dialect dbquery.Dialect
---@param columns dbquery.Column[]
---@return string
local function columnList(dialect, columns)
  return table.concat(vim.tbl_map(function(column)
    return names.quote(dialect, column.name)
  end, columns), ", ")
end

--- Returns the item that writes `written`, the table being completed, with its
--- column list and a values row: `trades (id, qty) values (id, qty)`.
---@param dialect dbquery.Dialect
---@param relation dbquery.Relation
---@param label string The table's name as the completion shows it.
---@param written string The table as the completion writes it.
---@param range lsp.Range
---@return lsp.CompletionItem|nil
function M.statement(dialect, relation, label, written, range)
  local columns = names.insertable(relation)
  if #columns == 0 then
    return nil
  end
  local text = escaped(written) .. " (" .. escaped(columnList(dialect, columns)) .. ") values (" .. placeholders(columns) .. ")$0"
  return {
    label = label .. " (…) values (…)",
    kind = Kind.Snippet,
    filterText = label,
    insertTextFormat = SNIPPET,
    textEdit = { range = range, newText = text },
    detail = #columns .. " columns",
  }
end

--- Returns the items for an insert's column list: while the list is empty, one
--- item writing every insertable column, and an item for each insertable
--- column not listed yet, in the table's order.
---@param dialect dbquery.Dialect
---@param relation dbquery.Relation
---@param listed string[] The columns already written.
---@param range lsp.Range
---@param quoting boolean The word under the cursor opens with a quote.
---@return lsp.CompletionItem|nil all
---@return lsp.CompletionItem[] columns
function M.columns(dialect, relation, listed, range, quoting)
  local taken = {}
  for _, name in ipairs(listed) do
    taken[names.parts(dialect, name)[1].text:lower()] = true
  end
  local items, remaining = {}, {}
  for _, column in ipairs(names.insertable(relation)) do
    if not taken[column.name:lower()] then
      remaining[#remaining + 1] = column
      local text = names.quote(dialect, column.name)
      items[#items + 1] = {
        label = column.name,
        kind = Kind.Field,
        detail = column.type,
        filterText = quoting and text or column.name,
        textEdit = { range = range, newText = text },
      }
    end
  end
  if #listed > 0 or #remaining < 2 then
    return nil, items
  end
  local text = columnList(dialect, remaining)
  return {
    label = "all columns",
    kind = Kind.Snippet,
    detail = text,
    filterText = "",
    textEdit = { range = range, newText = text },
  }, items
end

--- Returns the item that fills an empty values row for the columns `listed`,
--- or nil when no column list is written, since values without one would
--- land in whichever columns come first.
---@param relation dbquery.Relation|nil
---@param listed string[]|nil
---@param dialect dbquery.Dialect
---@param range lsp.Range
---@return lsp.CompletionItem|nil
function M.values(relation, listed, dialect, range)
  if not listed or #listed == 0 then
    return nil
  end
  local columns = vim.tbl_map(function(name)
    local text = names.parts(dialect, name)[1].text
    local found = relation and vim.iter(relation.columns):find(function(column)
      return column.name:lower() == text:lower()
    end)
    return { name = text, type = found and found.type }
  end, listed)
  return {
    label = "(" .. table.concat(vim.tbl_map(function(column)
      return column.name
    end, columns), ", ") .. ")",
    kind = Kind.Snippet,
    filterText = "",
    insertTextFormat = SNIPPET,
    textEdit = { range = range, newText = placeholders(columns) .. "$0" },
    detail = "values for the listed columns",
  }
end

return M
