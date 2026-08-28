# db-query.nvim

A SQL runner for Neovim, which utilizes command line clients to execute queries. This is just another take on the dadbod concept. The reason it exists is that I wanted more control over how the output was generated and managed.

Queries run through `psql`, `duckdb`, `sqlite3`, or `mysql`. Long scripts stream into the results window as they run. `<C-c>` cancels.

## Requirements

Neovim 0.11 or newer.

The client for your database, on your `PATH`. `stdbuf` from coreutils is used when it is there, which will enable postgres scripts to stream progress line by line instead of in large chunks.

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

The first time you run a query, db-query asks which database to use. The list opens through `vim.ui.select`, so you get whatever picker you have configured. Your choice is stored on the buffer until you change it, and new `.sql` buffers reuse the last connection. Use `:DBConnect` to point a buffer at a different database.

This was designed to fit within the [vim-dadbod](https://github.com/tpope/vim-dadbod) ecosystem, so if you use that then it will pick up your existing configured connections. If you have [vim-dadbod-completion](https://github.com/kristijanhusak/vim-dadbod-completion) installed, it will utilize the connection this plugin sets.

The list comes from [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui)'s `connections.json` (in `g:db_ui_save_location`, or `~/.local/share/db_ui`), then from `g:dbs`. Set `connections` to a list, or a function returning one, to read from somewhere else instead:

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

This needs [vim-dadbod](https://github.com/tpope/vim-dadbod) to expand variables. Without it, the URL is used exactly as you wrote it. A `$` that is part of a password rather than the start of a variable name has to be written `%24`.

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

| Command              |                                          |
|----------------------|------------------------------------------|
| `:DBQuery`           | Run the buffer                           |
| `:DBQueryStatement`  | Run the statement the cursor is in       |
| `:'<,'>DBQuery`      | Run the selection                        |
| `:1,20DBQuery`       | Run lines 1 to 20                        |
| `:DBQuery -f csv`    | Output CSV instead                       |
| `:DBQuery -o report` | Name the output file yourself            |
| `:DBConnect`         | Pick the database for this buffer        |
| `:DBOutputDir ~/out` | Set the output directory for this buffer |

`:DBQueryStatement` takes the lines between the semicolons on either side of the cursor. A semicolon inside a string literal ends the statement.

`-f csv` only applies to a single `select`. Anything else falls back to normal output. Pair it with something that renders CSV, like [csv-table.nvim](https://github.com/cseickel/csv-table.nvim). A query that fails writes the client's error into the csv as its only cell, so what renders the file shows the error rather than an empty table.

`-o` changes the output directory from the ephemral `~/.cache/nvim/db-query/<pid>` location to a permanent directory of your choice. The extension is set by the format, using `csv` or `tsv` for an export, depending on the client, and `log` for anything else. Each new query execution runs to a new file that is automatically named.

## Where output goes

Output is written to a directory in `stdpath("cache")/<pid>/`, one file per query, named for the sql buffer and auto numbered. A file is deleted with the window that showed it, and if nvim exited without cleaning up, it will be swept the next time one starts.

Set `output_dir` in `setup` to choose your own default output location. Set `output_cleanup = true` to have that directory auto delete it's contents when query buffer or nvim is closed.

`:DBOutputDir ~/exports` writes there instead, for the rest of the session, and those files will not be deleted by the plugin. You can reset the output path to the auto location by running `:DBOutputDir` with no args.

`-o` with no path will prompt for one, prefilled with the last path this buffer wrote. It applies to that one query, and the next query without it goes back to the configured output directory.

## Keys

The only key the plugin binds by default is `cancel`, and only while a query is running. Here are some example bindings:

```lua
vim.keymap.set("n", "<M-x>", function()
  require("db-query").execute()
end, { desc = "run the buffer" })

vim.keymap.set("x", "<M-x>", function()
  require("db-query").execute({ visual = true })
end, { desc = "run the selection" })

-- Ctrl-Enter: Execute the query the cursor is on in a file that may have multiple
-- statements, and output CSV
vim.keymap.set("n", "<C-CR>", function()
  require("db-query").execute({ statement = true, csv = true })
end, { buffer = event.buf, desc = "Execute query at cursor" })
```

`execute` takes `visual`, `range`, `statement`, `format`, and `output`, which is a path for the output file or `true` to be asked for one.

## While a query runs

A bar marks the lines that are running, continuing onto a line beneath them with a spinner, a clock, and the cancel key. The window showing the last run's output is greyed until the new output replaces it.

You can call `status(buf)` to get the same spinner and timer in your winbar or statusline:

```lua
local text = require("db-query").status(vim.api.nvim_get_current_buf())
if text ~= "" then
  return "%#StatusLineInfo# " .. text .. " %*"
end
```

## Highlights

`DbQueryIndicator` colors the bar and everything drawn under it. It links to `DiagnosticInfo` unless you set it:

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

## Contributing

[ARCHITECTURE.md](ARCHITECTURE.md) describes how it works. New data adapters are welcome, as are bug fixes. I make no guarantee about new features being accepted, so file an issue first so we can discuss it.
