--[[
The rules that differ between one database's sql and another's.

Each dialect file returns a `dbquery.Dialect`, built with `derive` from the
dialect it is closest to. Every module under `sql/` reads by the dialect it is
given.
]]

local M = {}

---@class dbquery.LexRules
---@field strings table<string, boolean> Quote characters that open a string, mapped to whether a backslash escapes the character after it.
---@field escapeStrings boolean `E'...'` is a string in which a backslash escapes.
---@field identifiers table<string, string> Characters that open a quoted identifier, mapped to the character that closes it.
---@field lineComments string[] Patterns matching the start of a comment that runs to the end of its line.
---@field nestedComments boolean A `/*` inside a block comment opens another level.
---@field dollarQuotes boolean `$tag$ ... $tag$` is a string.
---@field parameters string[] Patterns matching a parameter or variable, such as `$1` or `@total`.
---@field casts boolean `::` is the cast operator.

--- The commands a command-line client runs itself instead of sending them to
--- the server, such as psql's `\gset` or mysql's `delimiter //`.
---@class dbquery.Commands
---@field at fun(text: string, index: integer, lineStart: boolean): integer|nil Returns the last byte of the command starting at `index`, or nil when none starts there. `lineStart` is true when only whitespace precedes `index` on its line.
---@field variables string|nil Pattern matching a variable the client substitutes before sending, such as psql's `:name`.
---@field sends fun(text: string): boolean Returns true for a command that sends the query typed before it.
---@field delimiter (fun(text: string): string|nil)|nil Returns the statement delimiter a command sets in place of `;`, or nil for a command that sets none.

---@class dbquery.ClauseState
---@field after string|nil The word before this one, lowercased.
---@field clause dbquery.Clause The clause before this word.
---@field statement string|nil The first word of the statement or query block, lowercased.

---@class dbquery.ClauseRule
---@field word string
---@field clause dbquery.Clause The clause this word starts.
---@field after table<string, true>|nil The rule applies only after one of these words.
---@field within table<dbquery.Clause, true>|nil The rule applies only inside one of these clauses.
---@field test (fun(state: dbquery.ClauseState): boolean)|nil The rule applies only when this returns true.

--- One token of a pattern: a word, one of a set of words, `ANY` for any word,
--- or `GROUP` for a parenthesized group.
---@alias dbquery.PatternPart string|table<string, true>

--- A function the sql grammar defines rather than the catalog, such as
--- `extract(field from source)`.
---@class dbquery.GrammarSignature
---@field label string
---@field parameters string[] Comma-separated arguments in call order. Empty for a form whose arguments keywords separate, which no argument position can point into.
---@field variadic boolean The last parameter repeats.

--- The keywords completion offers, keyed by where the cursor stands.
---
--- Every `dbquery.Clause` name holds the words that may follow a value or a
--- name in that clause: `where` holds the clauses a query goes on with after
--- its where clause, `from` holds those plus the joins and `as`. Seven keys
--- are not clauses:
---
--- - `expression`: words that open a value.
--- - `operator`: words that may follow a value, other than a clause.
--- - `quantifier`: words that read a subquery, written after a comparison.
--- - `projection`: words written just after `select`, or as a call's first argument.
--- - `case`: words written inside an unclosed `case`.
--- - `call`: words written after a call, such as a window function's `over`.
--- - `closes`: reserved words that stand for a value or end one, such as
---   `null` and the `end` of a case, so a word after one follows a value.
---
--- A key a dialect leaves out offers nothing there.
---@alias dbquery.Keywords table<string, table<string, true>>

---@class dbquery.Dialect
---@field name string
---@field folds "lower"|"none" How the server reads an unquoted name: folded to lower case, or matched in any case.
---@field signatures table<string, dbquery.GrammarSignature> Keyed by lowercase function name.
---@field keywords dbquery.Keywords
---@field lex dbquery.LexRules
---@field commands dbquery.Commands|nil The client's own commands, for a dialect read the way one client reads it.
---@field reserved table<string, true> Words that are never an alias.
---@field queries table<string, true> Words that start a statement which returns or writes rows.
---@field definitions table<string, true> Words that start a statement which changes the catalog.
---@field clauses dbquery.ClauseRule[] Tried in order, and the first that applies labels the word.
---@field joins table<string, true> Words that start a join.
---@field beforeRelation table<string, true> Words other than joins that a table name may follow, such as `from` or `into`.
---@field callable table<string, true> Reserved words that name a function when `(` follows.
---@field fromSuffixes dbquery.PatternPart[][] What may follow a table in from, such as `tablesample system (10)`.
---@field blocks string[][] Words that open a body holding `;`, which closes at its `end`.

---@class dbquery.DialectChanges
---@field name string
---@field folds "lower"|"none"|nil
---@field signatures table<string, dbquery.GrammarSignature>|nil Replaces the base dialect's, since a dialect may lack a form its base has.
---@field keywords dbquery.Keywords|nil Replaces the base dialect's, since a dialect may lack a word its base has.
---@field lex table|nil Rules of `dbquery.LexRules`, each replacing the base dialect's.
---@field commands dbquery.Commands|nil
---@field reserved table<string, true>|nil Added.
---@field queries table<string, true>|nil Added.
---@field definitions table<string, true>|nil Added.
---@field clauses dbquery.ClauseRule[]|nil Tried before the base dialect's.
---@field joins table<string, true>|nil Added.
---@field beforeRelation table<string, true>|nil Added.
---@field callable table<string, true>|nil Added.
---@field fromSuffixes dbquery.PatternPart[][]|nil Added.
---@field blocks string[][]|nil Added.

M.ANY = "<word>"
M.GROUP = "(...)"

--- Returns the whitespace-separated words of `text` as a set.
---@param text string
---@return table<string, true>
function M.set(text)
  local found = {}
  for word in text:gmatch("%S+") do
    found[word] = true
  end
  return found
end

--- Returns the words of `base` that `text` does not name.
---@param base table<string, true>
---@param text string
---@return table<string, true>
function M.without(base, text)
  local found = vim.tbl_extend("force", {}, base)
  for word in text:gmatch("%S+") do
    found[word] = nil
  end
  return found
end

---@param base table<string, true>
---@param added table<string, true>|nil
---@return table<string, true>
local function union(base, added)
  return vim.tbl_extend("force", base, added or {})
end

--- Returns a dialect that is `base` with `changes` applied.
---@param base dbquery.Dialect
---@param changes dbquery.DialectChanges
---@return dbquery.Dialect
function M.derive(base, changes)
  return {
    name = changes.name,
    folds = changes.folds or base.folds,
    signatures = changes.signatures or base.signatures,
    keywords = changes.keywords or base.keywords,
    lex = vim.tbl_extend("force", base.lex, changes.lex or {}),
    commands = changes.commands or base.commands,
    reserved = union(base.reserved, changes.reserved),
    queries = union(base.queries, changes.queries),
    definitions = union(base.definitions, changes.definitions),
    clauses = vim.list_extend(vim.list_extend({}, changes.clauses or {}), base.clauses),
    joins = union(base.joins, changes.joins),
    beforeRelation = union(base.beforeRelation, changes.beforeRelation),
    callable = union(base.callable, changes.callable),
    fromSuffixes = vim.list_extend(vim.list_extend({}, base.fromSuffixes), changes.fromSuffixes or {}),
    blocks = vim.list_extend(vim.list_extend({}, base.blocks), changes.blocks or {}),
  }
end

return M
