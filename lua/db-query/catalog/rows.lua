--[[
Helpers for a catalog function that reads its catalog as rows of json.

- `collect` runs several queries at once and hands back every result.
- `decode` reads output holding one json object per line.
- `relations` groups rows holding one column each into relations.
- `labels` reads the values out of an `enum('a', 'b')` type.
- `text` turns an empty string into nil.

A query that prints one object per row keeps every value short, where one
aggregated document can be cut off by a server limit such as mariadb's
`group_concat_max_len`.
]]

local M = {}

--- Returns the objects in `output`, one json object per line, with json null
--- read as nil inside an object. Throws when a line is not json.
---@param output string
---@return table[]
function M.decode(output)
  local rows = {}
  for line in output:gmatch("[^\n]+") do
    if line:match("%S") then
      rows[#rows + 1] = vim.json.decode(line, { luanil = { object = true } })
    end
  end
  return rows
end

--- Runs every statement in `statements` at once with `request.timeout`, and
--- calls `done` once: with the decoded rows of each, under the same key, when
--- all of them succeed, or with the first error.
---@param request dbquery.CatalogRequest
---@param statements table<string, string>
---@param done fun(rows: table<string, table[]>|nil, err: string|nil)
function M.collect(request, statements, done)
  local rows, pending, failed = {}, vim.tbl_count(statements), false
  if pending == 0 then
    return done(rows)
  end
  for key, statement in pairs(statements) do
    request.query(statement, { timeout = request.timeout }, function(output, err)
      if failed then
        return
      end
      if not output then
        failed = true
        return done(nil, err)
      end
      rows[key] = M.decode(output)
      pending = pending - 1
      if pending == 0 then
        done(rows)
      end
    end)
  end
end

--- Returns the relations in `rows`, which hold one column each, grouped by
--- their `database`, `schema`, and `name` fields. Rows of one relation must be
--- adjacent and in column order. `column` returns nil for the row of a
--- relation with no columns.
---@param rows table[]
---@param relation fun(row: table): dbquery.Relation Builds the relation from its first row, columns left empty.
---@param column fun(row: table): dbquery.Column|nil
---@return dbquery.Relation[]
function M.relations(rows, relation, column)
  local found, current, first = {}, nil, nil
  for _, row in ipairs(rows) do
    if not (first and first.name == row.name and first.schema == row.schema and first.database == row.database) then
      first, current = row, relation(row)
      found[#found + 1] = current
    end
    local built = column(row)
    if built then
      table.insert(current.columns, built)
    end
  end
  return found
end

--- Returns the values of an `enum('a', 'b')` type, in any letter case, with
--- a doubled quote read as one. Returns nil for any other type.
---@param type string|nil
---@return string[]|nil
function M.labels(type)
  local list = type and type:match("^%s*[Ee][Nn][Uu][Mm]%s*%((.*)%)%s*$")
  if not list then
    return nil
  end
  local labels, index = {}, 1
  while true do
    local open = list:find("'", index, true)
    if not open then
      return labels
    end
    local value, at = {}, open + 1
    while at <= #list do
      local close = list:find("'", at, true)
      if not close then
        return labels
      end
      value[#value + 1] = list:sub(at, close - 1)
      if list:sub(close + 1, close + 1) ~= "'" then
        at = close + 1
        break
      end
      value[#value + 1] = "'"
      at = close + 2
    end
    labels[#labels + 1] = table.concat(value)
    index = at
  end
end

--- Returns `text`, or nil when it is empty.
---@param text string|nil
---@return string|nil
function M.text(text)
  return text ~= "" and text or nil
end

return M
