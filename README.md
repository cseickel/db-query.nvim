# db-query.nvim

A SQL runner for Neovim, built on the command line clients you already have.

Queries run through `psql`, `duckdb`, `sqlite3` or `mysql`. Long scripts stream into the results window as they run. `<C-c>` cancels.

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

The first time you run a query, db-query asks which database to run it against. The list opens through `vim.ui.select`, so you get whatever picker you have configured. This will be stored on the buffer until you change it, and new `.sql` buffers will reuse the last connection by default. Use `:DBConnect` to point a buffer at a different database.

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

This needs vim-dadbod installed, which is what expands them. Without it, the URL is used exactly as you wrote it. A `$` that is part of a password rather than the start of a variable name has to be written `%24`.

A connection is a table with a name and a vim-dadbod URL, and the one you pick is stored in `b:db`. That is the variable vim-dadbod and `vim-dadbod-completion` read, so completion follows your choice, and anything else that sets `b:db` works without going through the chooser at all. [neo-tree-database.nvim](https://github.com/cseickel/neo-tree-database.nvim) opens its scratch buffers that way.

## Options

This shows the default options, which are all optional. Anything you do set will merge into and override these defaults.

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
})
```

## Commands

| Command           |                                   |
|-------------------|-----------------------------------|
| `:DBQuery`        | Run the buffer                    |
| `:'<,'>DBQuery`   | Run the selection                 |
| `:1,20DBQuery`    | Run lines 1 to 20                 |
| `:DBQuery -f csv` | Output CSV instead                |
| `:DBConnect`      | Pick the database for this buffer |

`-f csv` only applies to a single `select`. Anything else falls back to normal output. Pair it with something that renders CSV, like [csv-table.nvim](https://github.com/cseickel/csv-table.nvim).

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

`execute` takes `visual`, `range` and `format`.

## While a query runs

The lines that ran are highlighted, and a spinner, a clock and the cancel key are drawn under them.

Those scroll away with the query. `status` puts the same spinner somewhere that does not, returning `⠹ 3.4s` while that buffer is running something and an empty string when it is not:

```lua
local text = require("db-query").status(vim.api.nvim_get_current_buf())
if text ~= "" then
  return "%#StatusLineInfo# " .. text .. " %*"
end
```

## Highlights

These groups are used while a query runs:

| Group               | Links to         | Used for                     |
| ------------------- | ---------------- | ---------------------------- |
| `DbQueryRunning`    | `CursorLine`     | The lines that ran            |
| `DbQuerySpinner`    | `DiagnosticInfo` | The spinner                  |
| `DbQueryElapsed`    | `Comment`        | The seconds it has been running |
| `DbQueryCancelHint` | `NonText`        | The reminder of the cancel key |

## Parquet

If you enable `parquet = true`, opening a `.parquet` file will trigger a query through duckdb instead. The buffer will keep the original name with the extension changed to `.sql`. The duckdb instance used is a throwaway and loads the file as a view to the file on disk so that `vim-dadbod-completions` can pull the metadata. It does not actually import the data.

This won't work with lazy loading, because the plugin has to be enabled to intercept the file:

```lua
{
  "cseickel/db-query.nvim",
  lazy = false,
  opts = { parquet = true },
}
```
