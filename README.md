# db-query.nvim

A SQL runner for Neovim, built on the command line clients you already have.

Queries run through `psql`, `duckdb`, `sqlite3`, or `mysql`. Long scripts stream into the results window as they run. `<C-c>` cancels.

[ARCHITECTURE.md](ARCHITECTURE.md) describes how it works inside, and how to add a database.

## Requirements

Neovim 0.11 or newer.

The client for your database, on your `PATH`. `stdbuf` from coreutils is used when it is there, and without it a long script arrives in chunks instead of line by line.

## Install

With lazy.nvim:

```lua
{
  "cseickel/db-query.nvim",
  ft = { "sql", "mysql", "plsql" },
  opts = {},
}
```

## Connections

The first time you run a query, db-query asks which database to use. The list opens through `vim.ui.select`, so you get whatever picker you have configured. Your choice is stored on the buffer until you change it, and new `.sql` buffers reuse the last connection. Use `:DBConnect` to point a buffer at a different database. Completion follows the change: vim-dadbod-completion reads the connection once per buffer and keeps what it found, so `:DBConnect` tells it to fetch again.

The list comes from vim-dadbod-ui's `connections.json` (in `g:db_ui_save_location`, or `~/.local/share/db_ui`), then from `g:dbs`. Set `connections` to a list, or a function returning one, to read from somewhere else instead:

```lua
opts = {
  connections = function()
    return {
      { name = "warehouse", url = "postgres://app@db.internal/warehouse" },
    }
  end,
}
```

A URL can hold environment variables, so your connections file does not have to hold a password:

```json
[
  { "name": "warehouse", "url": "postgres://app:$PGPASS@db.internal/warehouse" }
]
```

This needs vim-dadbod, which expands them. Without it, the URL is used exactly as you wrote it. A `$` that is part of a password rather than the start of a variable name has to be written `%24`.

A connection is a table with a name and a vim-dadbod URL, and the one you pick is stored in `b:db`. That is the variable vim-dadbod and vim-dadbod-completion read, so completion follows your choice. Anything else that sets `b:db` works without the chooser. [neo-tree-database.nvim](https://github.com/cseickel/neo-tree-database.nvim) opens its scratch buffers that way.

## Options

These are the defaults. Anything you set merges into them.

```lua
require("db-query").setup({
  -- Where the chooser gets its list, replacing the built-in sources. A list of
  -- { name, url } tables, or a function returning one. See Connections above.
  connections = nil,

  -- Open a `.parquet` file as a duckdb query against it.
  parquet = false,

  -- The key that stops a running query, bound only while one is running. You
  -- can change it, but not disable it.
  -- Omitting this setting will just revert it to the default.
  cancel = "<C-c>",
  
  -- The format to use for the output pane. The default is "text", which is
  -- native cli output. The other option is "csv", which exports to csv when the
  -- query is a single row-returning statement.
  format = "text",

  -- Where output files are written. The default is a directory of this nvim's
  -- own under `stdpath("cache")`.
  output_dir = nil,

  -- Whether an output file is deleted with the window that showed it, and
  -- whether what an nvim left behind is swept at startup. Setting `output_dir`
  -- and leaving this alone turns it off, since a directory of your own is
  -- somewhere you put results you are keeping.
  output_cleanup = true,
})
```

## Commands

| Command              |                                    |
|----------------------|------------------------------------|
| `:DBQuery`           | Run the buffer                     |
| `:DBQueryStatement`  | Run the statement the cursor is in |
| `:'<,'>DBQuery`      | Run the selection                  |
| `:1,20DBQuery`       | Run lines 1 to 20                  |
| `:DBQuery -f csv`    | Output CSV instead                 |
| `:DBQuery -o report` | Name the output file yourself      |
| `:DBConnect`         | Pick the database for this buffer  |
| `:DBOutputDir ~/out` | Write output there and keep it     |

`:DBQueryStatement` takes the lines between the semicolons on either side of the cursor. A semicolon inside a string literal ends the statement.

`-f csv` only applies to a single `select`. Anything else falls back to normal output. Pair it with something that renders CSV, like [csv-table.nvim](https://github.com/cseickel/csv-table.nvim). A query that fails writes the client's error into the csv as its only cell, so what renders the file shows the error rather than an empty table.

`-o` writes the output where you say, and `<Tab>` completes the path. Give it the name without an extension, because the extension is the client's to choose: `csv` or `tsv` for an export, `log` for anything else. `-o report` with `-f csv` writes `report.csv`, and a name ending in any of those three has that one replaced, so `-o report.csv` without `-f csv` writes `report.log`. A relative path starts from the working directory, and a path ending in `/`, or naming a directory, puts a file named after the sql buffer inside it.

A file you named is yours: `:w` saves it, a session restores it, and closing its window leaves it where it is. What is deleted is decided by the directory rather than by who named the file, so a `-o` into a directory you asked to have cleared up is cleared up too. A file that already exists asks before being overwritten, and answering Cancel runs nothing. The one place `-o` cannot point is the plugin's own cache directory, which is cleared on startup.

## Where output goes

Output is written to a directory of this nvim's own under `stdpath("cache")`, one file per query, named for the sql buffer and numbered one past whatever is already there. A file is deleted with the window that showed it, and whatever an nvim exited without clearing up is swept the next time one starts.

`:DBOutputDir ~/exports` writes there instead, for the rest of the session, and nothing written there is deleted. Naming a directory while you work is how you say you are keeping what lands in it. `<Tab>` completes the path, and `:DBOutputDir` with no path asks, offering the one in use. Emptying that prompt puts it back to the directory `setup` gave.

`output_dir` in `setup` is the same choice made once, and `output_cleanup` is how you ask for a directory of your own that is still cleared up.

`-o` with no path asks for one, prefilled with the last path this buffer wrote, so rerunning an export is a matter of pressing enter. It applies to that one query, and the next query without it goes back to the cache directory.

## Keys

The only key the plugin binds by default is `cancel`, and only while a query is running. Everything else is yours:

```lua
vim.keymap.set("n", "<M-x>", function()
  require("db-query").execute()
end, { desc = "run the buffer" })

vim.keymap.set("x", "<M-x>", function()
  require("db-query").execute({ visual = true })
end, { desc = "run the selection" })
```

`execute` takes `visual`, `range`, `statement`, `format`, and `output`, which is a path for the output file or `true` to be asked for one.

## While a query runs

A bar marks the lines that ran, continuing onto a line beneath them with a spinner, a clock, and the cancel key. The bar scrolls with the query, and the window showing the last run's output is greyed until the new output replaces it. `status` puts the same spinner somewhere that does not scroll, returning `⠹ 3.4s` while that buffer is running something and an empty string when it is not. Asked about a results buffer, it answers for the query filling it in:

```lua
local text = require("db-query").status(vim.api.nvim_get_current_buf())
if text ~= "" then
  return "%#StatusLineInfo# " .. text .. " %*"
end
```

## Highlights

`DbQueryIndicator` colours the bar and everything drawn under it. It links to `DiagnosticInfo` unless you set it:

```lua
vim.api.nvim_set_hl(0, "DbQueryIndicator", { fg = "#7aa2f7" })
```

## Parquet

With `parquet = true`, opening a `.parquet` file runs a query through duckdb instead. The buffer keeps the original name with the extension changed to `.sql`. The duckdb instance is ephemeral and loads the parquet file as a view so that vim-dadbod-completion can read the schema. It does not import the data.

This won't work with lazy loading, because the plugin has to be enabled to intercept the file:

```lua
{
  "cseickel/db-query.nvim",
  lazy = false,
  opts = { parquet = true },
}
```
