--[[
Matching the names sql writes against the names in a catalog.

- `parts` splits a dotted name, keeping a quoted part whole.
- `matches` says whether a part of a written name names a catalog name.
- `relation`, `type`, `relationsIn`, and `functions` find what a name refers
  to in the catalog, by the dialect's `folds` rule.
- `insertable` lists the columns of a table an insert lists.
- `quote` and `callable` write a catalog name the way sql has to spell it.
]]

local M = {}

---@class dbquery.NamePart
---@field text string The name with any quotes removed.
---@field quoted boolean

--- Returns the parts of a dotted name as written, such as `public."My Table"`.
---@param dialect dbquery.Dialect
---@param name string
---@return dbquery.NamePart[]
function M.parts(dialect, name)
  local found, index = {}, 1
  while index <= #name do
    local close = dialect.lex.identifiers[name:sub(index, index)]
    if close then
      local text, at = {}, index + 1
      while at <= #name do
        local char = name:sub(at, at)
        if char == close and name:sub(at + 1, at + 1) == close then
          text[#text + 1], at = close, at + 2
        elseif char == close then
          break
        else
          text[#text + 1], at = char, at + 1
        end
      end
      found[#found + 1] = { text = table.concat(text), quoted = true }
      index = at + 2
    else
      local dot = name:find(".", index, true) or #name + 1
      found[#found + 1] = { text = name:sub(index, dot - 1), quoted = false }
      index = dot + 1
    end
  end
  return found
end

--- Returns true when `part` names `name`. A quoted part matches exactly. An
--- unquoted part matches the name the dialect folds it to, or any case when
--- `loose`.
---@param dialect dbquery.Dialect
---@param part dbquery.NamePart
---@param name string|nil
---@param loose boolean
---@return boolean
function M.matches(dialect, part, name, loose)
  if name == nil then
    return false
  end
  if part.quoted then
    return part.text == name
  end
  if loose or dialect.folds == "none" then
    return part.text:lower() == name:lower()
  end
  return part.text:lower() == name
end

--- Returns the items of `list` whose qualified name `parts` names: the last
--- part against `name`, and the parts before it against `schema` and then
--- `database`. A single part is looked for in `searchPath` order, and then
--- anywhere when exactly one item has that name. Folded matches are tried
--- before matches in any case.
---@generic T : { database: string|nil, schema: string|nil, name: string }
---@param catalog dbquery.Catalog
---@param dialect dbquery.Dialect
---@param list T[]
---@param parts dbquery.NamePart[]
---@return T[]
local function qualified(catalog, dialect, list, parts)
  for _, loose in ipairs({ false, true }) do
    local found = {}
    local last = parts[#parts]
    if #parts == 1 then
      for _, path in ipairs(catalog.searchPath) do
        for _, item in ipairs(list) do
          local inPath = item.schema == path.schema and (path.database == nil or item.database == path.database)
          if inPath and M.matches(dialect, last, item.name, loose) then
            found[#found + 1] = item
          end
        end
        if #found > 0 then
          return found
        end
      end
      for _, item in ipairs(list) do
        if M.matches(dialect, last, item.name, loose) then
          found[#found + 1] = item
        end
      end
      local schemas = {}
      for _, item in ipairs(found) do
        schemas[(item.database or "") .. "." .. (item.schema or "")] = true
      end
      if vim.tbl_count(schemas) == 1 then
        return found
      end
    else
      local schema, database = parts[#parts - 1], parts[#parts - 2]
      for _, item in ipairs(list) do
        local inSchema = M.matches(dialect, schema, item.schema, loose)
        -- duckdb's `db.table` names the database's main schema.
        local inDatabase = #parts == 2 and item.schema == "main" and M.matches(dialect, schema, item.database, loose)
        if (database == nil or M.matches(dialect, database, item.database, loose)) and (inSchema or inDatabase)
          and M.matches(dialect, last, item.name, loose) then
          found[#found + 1] = item
        end
      end
      if #found > 0 then
        return found
      end
    end
  end
  return {}
end

--- Returns the catalog relation a dotted name written in sql refers to.
---@param catalog dbquery.Catalog
---@param dialect dbquery.Dialect
---@param name string
---@return dbquery.Relation|nil
function M.relation(catalog, dialect, name)
  return qualified(catalog, dialect, catalog.relations, M.parts(dialect, name))[1]
end

--- Returns the catalog type a dotted name written in sql refers to.
---@param catalog dbquery.Catalog
---@param dialect dbquery.Dialect
---@param name string
---@return dbquery.Type|nil
function M.type(catalog, dialect, name)
  return qualified(catalog, dialect, catalog.types, M.parts(dialect, name))[1]
end

--- Returns every overload of the function a dotted name written in sql refers to.
---@param catalog dbquery.Catalog
---@param dialect dbquery.Dialect
---@param name string
---@return dbquery.Function[]
function M.functions(catalog, dialect, name)
  local parts = M.parts(dialect, name)
  local found = qualified(catalog, dialect, catalog.functions, parts)
  if #found > 0 or #parts > 1 then
    return found
  end
  -- sqlite functions belong to no schema.
  return vim.iter(catalog.functions):filter(function(fn)
    return fn.schema == nil and M.matches(dialect, parts[1], fn.name, true)
  end):totable()
end

--- Returns the relations and functions in the schema a dotted name refers to,
--- such as `public` or duckdb's `db.main`, or in the main schema of the
--- database it names.
---@param catalog dbquery.Catalog
---@param dialect dbquery.Dialect
---@param name string
---@return dbquery.Relation[] relations
---@return dbquery.Function[] functions
function M.relationsIn(catalog, dialect, name)
  local parts = M.parts(dialect, name)
  local schema, database = parts[#parts], parts[#parts - 1]
  local function inside(item)
    if database then
      return M.matches(dialect, database, item.database, true) and M.matches(dialect, schema, item.schema, true)
    end
    return M.matches(dialect, schema, item.schema, true) or (item.schema == "main" and M.matches(dialect, schema, item.database, true))
  end
  return vim.iter(catalog.relations):filter(inside):totable(), vim.iter(catalog.functions):filter(inside):totable()
end

--- Returns the columns of `relation` an insert lists: every one the database
--- does not fill itself, and none it hides.
---@param relation dbquery.Relation
---@return dbquery.Column[]
function M.insertable(relation)
  return vim.iter(relation.columns):filter(function(column)
    return column.generated == nil and not column.hidden
  end):totable()
end

---@param dialect dbquery.Dialect
---@param name string
---@param reserved boolean A word the dialect reserves needs quotes too.
---@return string
local function spelled(dialect, name, reserved)
  local plain = name:match("^[%a_][%w_$]*$") ~= nil
  local readBack = dialect.folds == "none" or name == name:lower()
  if plain and readBack and not (reserved and dialect.reserved[name:lower()]) then
    return name
  end
  local open, close = next(dialect.lex.identifiers)
  return open .. name:gsub(vim.pesc(close), close .. close) .. close
end

--- Returns the name of a table, schema, or column as sql has to write it: bare
--- when the dialect reads the bare word back as this name, and quoted when it
--- would not, or when the dialect reserves the word, as in `"order"`.
---@param dialect dbquery.Dialect
---@param name string
---@return string
function M.quote(dialect, name)
  return spelled(dialect, name, true)
end

--- Returns a function's name as a call writes it, which a reserved word never
--- quotes: `coalesce(` is grammar, and `"coalesce"(` is not.
---@param dialect dbquery.Dialect
---@param name string
---@return string
function M.callable(dialect, name)
  return spelled(dialect, name, false)
end

return M
