--[[
The completion items one request collects, in the order they sort.
]]

local M = {}

--- Items sort by group in this order, whatever their kind.
M.GROUP = { insert = 0, column = 1, alias = 2, variable = 3, relation = 4, schema = 5, keyword = 6, ["function"] = 7 }

---@class dbquery.Completion
---@field opened dbquery.Opened
---@field context dbquery.CursorContext
---@field range lsp.Range
---@field snippets boolean The client accepts snippets.
---@field items lsp.CompletionItem[]
---@field seen table<string, true> Labels already offered, per group.
---@field quoting boolean The word under the cursor opens with a quote, so items are matched as they are written rather than by name.

--- Appends `item` to the items, sorted into `group`.
---@param state dbquery.Completion
---@param item lsp.CompletionItem
---@param group integer
---@return lsp.CompletionItem
function M.append(state, item, group)
  item.sortText = string.format("%d%05d", group, #state.items + 1)
  state.items[#state.items + 1] = item
  return item
end

--- Appends `item`, which writes `text` over the word under the cursor, unless
--- its group already holds an item with its label. Returns the item, or nil
--- when the label was already offered.
---@param state dbquery.Completion
---@param group integer
---@param text string The name as sql writes it.
---@param item lsp.CompletionItem
---@return lsp.CompletionItem|nil
function M.add(state, group, text, item)
  local key = group .. "\0" .. item.label
  if state.seen[key] then
    return nil
  end
  state.seen[key] = true
  item.filterText = state.quoting and text or item.label
  item.textEdit = { range = state.range, newText = text }
  return M.append(state, item, group)
end

return M
