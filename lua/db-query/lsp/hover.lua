--[[
Hover for the name under the cursor: a column, a table, or a function, as the
catalog describes it.
]]

local names = require("db-query.lsp.names")

local M = {}

---@param lines string[]
---@param text string|nil
local function comment(lines, text)
  if text and text ~= "" then
    vim.list_extend(lines, { "", text })
  end
end

--- Returns the parts that are not nil, joined by `separator`.
---@param separator string
---@param ... string|nil
---@return string
local function joined(separator, ...)
  local parts = {}
  for index = 1, select("#", ...) do
    local part = select(index, ...)
    if part ~= nil then
      parts[#parts + 1] = part
    end
  end
  return table.concat(parts, separator)
end

---@param relation dbquery.Relation
---@return string
local function qualifiedName(relation)
  return joined(".", relation.database, relation.schema, relation.name)
end

---@param column dbquery.Column
---@return string
local function columnLine(column)
  local filled = column.generated and ("generated " .. column.generated)
    or (column.default and ("default " .. column.default))
    or nil
  return joined(" ", column.name, column.type, (not column.nullable) and "not null" or nil, filled)
end

---@param column dbquery.Column
---@param relation dbquery.Relation|nil
---@return string[]
local function describeColumn(column, relation)
  local lines = { "```sql", (relation and (qualifiedName(relation) .. ".") or "") .. columnLine(column), "```" }
  if column.labels then
    vim.list_extend(lines, { "", "values: " .. table.concat(column.labels, ", ") })
  end
  comment(lines, column.comment)
  return lines
end

---@param relation dbquery.Relation
---@return string[]
local function describeRelation(relation)
  local lines = { "```sql", relation.kind .. " " .. qualifiedName(relation) }
  for _, column in ipairs(relation.columns) do
    lines[#lines + 1] = "  " .. columnLine(column)
  end
  lines[#lines + 1] = "```"
  comment(lines, relation.comment)
  return lines
end

---@param functions dbquery.Function[]
---@return string[]
local function describeFunctions(functions)
  local lines = {}
  for _, fn in ipairs(functions) do
    local args = vim.tbl_map(function(arg)
      return joined(" ", arg.mode ~= "in" and arg.mode or nil, arg.name, arg.type)
    end, fn.args)
    if #lines > 0 then
      lines[#lines + 1] = ""
    end
    vim.list_extend(lines, {
      "```sql",
      fn.kind .. " " .. (fn.schema and (fn.schema .. ".") or "") .. fn.name .. "(" .. table.concat(args, ", ") .. ")"
        .. (fn.result and (" → " .. fn.result) or ""),
      "```",
    })
    comment(lines, fn.comment)
  end
  return lines
end

--- Returns the description of the column `word` among the columns `relation`
--- offers, when the catalog knows it.
---@param opened dbquery.Opened
---@param relation dbquery.ScopeRelation
---@param word string
---@return string[]|nil
local function scopeColumn(opened, relation, word)
  local dialect = opened.document.dialect
  local part = names.parts(dialect, word)[1]
  for _, offered in ipairs(names.columns(opened.catalog, dialect, relation)) do
    if offered.column and offered.name:lower() == part.text:lower() then
      return describeColumn(offered.column, offered.relation)
    end
  end
  return nil
end

---@param opened dbquery.Opened
---@param name string
---@param calls boolean The name is followed by `(`.
---@return string[]|nil
local function catalogName(opened, name, calls)
  local catalog, dialect = opened.catalog, opened.document.dialect
  local relation = not calls and names.relation(catalog, dialect, name)
  if relation then
    return describeRelation(relation)
  end
  local functions = names.functions(catalog, dialect, name)
  return #functions > 0 and describeFunctions(functions) or nil
end

--- Returns, as markdown, the column, table, or function overloads the catalog
--- holds under the word in `context`, or nil when the catalog holds none.
---@param opened dbquery.Opened
---@param context dbquery.CursorContext
---@return lsp.Hover|nil
function M.hover(opened, context)
  local word, catalog = context.word.text, opened.catalog
  if word == "" or not catalog then
    return nil
  end
  local dialect = opened.document.dialect
  local calls = opened.document.text:sub(context.word.last + 1):match("^%s*%(") ~= nil
  local lines

  if context.kind == "qualified" then
    local matched = false
    for _, relation in ipairs(context.scope) do
      if names.refersTo(dialect, relation, context.qualifier) and #names.columns(catalog, dialect, relation) > 0 then
        matched, lines = true, scopeColumn(opened, relation, word)
        break
      end
    end
    if not matched then
      lines = scopeColumn(opened, { kind = "table", name = context.qualifier }, word)
        or catalogName(opened, context.qualifier .. "." .. word, calls)
    end
  elseif context.kind == "insert_columns" or context.kind == "columns_of" then
    local table = context.kind == "columns_of" and context.columnsOf or context.insert.table
    lines = scopeColumn(opened, { kind = "table", name = table }, word)
  elseif context.kind == "relation" then
    lines = catalogName(opened, word, calls)
  else
    for _, relation in ipairs(context.scope) do
      if not calls and names.reference(dialect, relation) and names.refersTo(dialect, relation, word)
        and relation.kind == "table" and relation.name then
        lines = catalogName(opened, relation.name, false)
        break
      end
    end
    if not lines and not calls then
      for _, relation in ipairs(context.scope) do
        lines = scopeColumn(opened, relation, word)
        if lines then
          break
        end
      end
    end
    lines = lines or catalogName(opened, word, calls)
  end

  if not lines then
    return nil
  end
  return { contents = { kind = "markdown", value = table.concat(lines, "\n") } }
end

return M
