# db-query.nvim

A SQL runner for Neovim, which utilizes command line clients to execute queries. This is just another take on the dadbod concept. I wrote it to control how the output is written and where it goes.

Queries run through `psql`, `duckdb`, `sqlite3`, `mysql`, or `mariadb`. Everything the client prints goes to a log that fills in as the query runs. Rows go to a file of their own, which replaces the log on screen when the query finishes. `<C-c>` cancels.

## Requirements

Neovim 0.11 or newer.

The client for your database, on your `PATH`. `stdbuf` from coreutils is used when it is there, so the log fills in line by line instead of in large chunks.

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

A connection is tested with `select 1` before the buffer takes it. One that fails, or gives no answer within 10 seconds, leaves the buffer with no connection and `b:db_name` reading `<name> CONNECTION ERROR`, and the next query opens the picker. A query you run while the test is under way is refused, and you run it again once the test answers. sqlite and duckdb files are taken without a test.

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

A `mysql://` or `mariadb://` URL can end in client options, which are passed to the client as they are in vim-dadbod. `mariadb://app@db.internal/warehouse?ssl-verify-server-cert=0` runs `mariadb --ssl-verify-server-cert=0`. Postgres URLs take options the same way, read by `psql` itself.

A connection is a table with a name and a vim-dadbod URL, and the one you pick is stored in `b:db`. vim-dadbod and vim-dadbod-completion read `b:db`, so completion uses the database you picked. Anything else that sets `b:db` works without the chooser. [neo-tree-database.nvim](https://github.com/cseickel/neo-tree-database.nvim) opens its scratch buffers that way.

## Naming the connection in the file

A comment in the first or last five lines of a file names the connection that file runs against:

```sql
select * from orders;

-- @db-query connection=[rva-3-dev]
```

The name is one from the list the picker shows. The brackets are needed only when the name has a space in it, and `connection` can be cut to any length, so `c=rva-3-dev` works too.

The comment is read when the file opens and every time it is written, so an edit takes effect when you save. It takes precedence over the last connection you picked, and it never changes the connection other buffers start with. A name missing from the list, or a connection that fails its test, leaves the buffer with no connection rather than on some other database.

`:DBConnect` in a file with the comment asks before replacing the name in it, and cancelling leaves the comment and the connection as they were. Deleting the comment and saving leaves the buffer on the connection it had.

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

  -- The format of the results file. "text" is the client's own table, written
  -- to a .txt file. "csv" is delimited rows, written to a .csv file (.tsv for
  -- mysql and mariadb).
  format = "text",

  -- Where results files are written. The default is a directory of this nvim's
  -- own under `stdpath("cache")`.
  output_dir = nil,

  -- Whether a results file is deleted with the sql buffer that produced it,
  -- and whether what an nvim left behind is swept at startup. Setting
  -- `output_dir` and leaving this alone turns it off, since a directory of
  -- your own is somewhere you put results you are keeping.
  output_cleanup = true,
})
```

## Commands

| Command              |                                                |
|----------------------|------------------------------------------------|
| `:DBQuery`           | Run the buffer                                 |
| `:DBQueryStatement`  | Run the statement the cursor is in             |
| `:'<,'>DBQuery`      | Run the selection                              |
| `:1,20DBQuery`       | Run lines 1 to 20                              |
| `:DBQuery -f csv`    | Write the rows as CSV instead                  |
| `:DBQuery -o report` | Name the results file yourself                 |
| `:DBOutput`          | Switch the output window between log and rows  |
| `:DBOutput log`      | Show the log                                   |
| `:DBOutput result`   | Show the last query's rows                     |
| `:DBConnect`         | Pick the database for this buffer              |
| `:DBOutputDir ~/out` | Set the output directory for the session       |

`:DBQueryStatement` takes the lines of the statement under the cursor. A statement ends at a `;` outside a string, a comment, or a function body, at a psql command that sends the query, such as `\gset`, or at a psql command line ending in `;`. The text is read by the rules of the buffer's database, so a `\'` inside a mysql string stays inside the string, and a `#` comment or a backtick name is read as one on mysql and mariadb.

On mysql and mariadb a statement also ends at `\G` and at a `delimiter` line, and after `delimiter //` it ends at `//` instead of `;`, so the statement under the cursor in a `create procedure` is the whole procedure. A statement run from below a `delimiter //` line is sent with that line ahead of it, so the client ends it where the buffer does.

Every query appends what the client prints to the buffer's log. A query that returns rows, meaning a single `select`, `with`, `table`, or `values` statement, or an `insert`, `update`, `delete`, or `merge` with a `RETURNING` clause, also writes those rows to a results file. Anything else, such as a script of several statements, a postgres statement with a psql backslash command in it, a mysql statement ended with `\G`, or a mutation without `RETURNING`, writes only to the log, where the client's command tags and row counts land.

`-f csv` writes the results file as delimited rows in place of the client's table. Pair it with something that renders CSV, like [csv-table.nvim](https://github.com/cseickel/csv-table.nvim). mysql and mariadb write tab-separated rows, so their file is `.tsv`.

`-o` names the results file for one query, in place of the one the plugin would have named. `-o report` writes `report.txt` or `report.csv` in the working directory, depending on the format, `-o ~/exports/` writes into that directory under the buffer's own name, and an existing file is confirmed before the query starts. The extension is always set by the format, so `-o report.csv` on a text query writes `report.txt`. A query that returns no rows has no results file, so `-o` on one warns that nothing will be written there. `-o` with no path prompts for one, prefilled with the last path this buffer wrote. It applies to that one query, and the next query without it goes back to the output directory.

`:DBOutput` opens the output window if it was closed and swaps between the log and the last query's rows. It works from the sql buffer and from the output window. `:DBOutput result` after a query that failed, or that returned no rows, says so and leaves the window alone.

## Where output goes

The log for a buffer is `stdpath("cache")/db-query/<pid>/<buffer name>.log`. Every query run from that buffer appends to it, each under a header with the run's number, the time, and the sql. The log is deleted when the sql buffer is wiped, and anything an nvim left behind is swept the next time one starts.

Results files go to the output directory, which defaults to the same `stdpath("cache")/db-query/<pid>/`, named for the sql buffer and numbered one past the highest number already there. They are ordinary buffers, so closing the window keeps the file, and `:DBOutput` brings it back. Results files are deleted when the sql buffer that produced them is wiped.

Set `output_dir` in `setup` to write results somewhere else. That turns `output_cleanup` off, because a directory of your own is somewhere you put results you are keeping. Set `output_cleanup = true` alongside it to have those files deleted with their sql buffer anyway.

`:DBOutputDir ~/exports` writes results there for the rest of the session, and nothing written there is ever deleted by the plugin. `:DBOutputDir` with no argument prompts for a directory, and emptying the prompt puts it back to what `setup` was given.

## Keys

The only key the plugin binds by default is `cancel`, and only while a query is running. Here are some example bindings:

```lua
vim.keymap.set("n", "<M-x>", function()
  require("db-query").execute()
end, { desc = "run the buffer" })

vim.keymap.set("x", "<M-x>", function()
  require("db-query").execute({ visual = true })
end, { desc = "run the selection" })

-- Ctrl-Enter: run the statement the cursor is on in a file that may have
-- multiple statements, and write the rows as CSV
vim.keymap.set("n", "<C-CR>", function()
  require("db-query").execute({ statement = true, format = "csv" })
end, { desc = "run the statement at the cursor" })

vim.keymap.set("n", "<M-o>", function()
  require("db-query").output("toggle")
end, { desc = "switch between the log and the rows" })
```

`execute` takes `visual`, `range`, `statement`, `format`, and `output`, which is a path for the results file or `true` to be asked for one. `output` takes `"log"`, `"result"`, or `"toggle"`, the same as `:DBOutput`.

## While a query runs

A bar marks the lines that are running, continuing onto a line beneath them with a spinner, a clock, and the cancel key. The output window shows the log, reloaded every half second, so a long script fills in as it goes. Rows you are already looking at stay on screen instead, so a rerun does not take them away while it works. When the query finishes with rows, the window switches to them. When it fails or is cancelled, the log comes up with the reason at the bottom.

You can call `status(buf)` to get the same spinner and timer in your winbar or statusline:

```lua
local text = require("db-query").status(vim.api.nvim_get_current_buf())
if text ~= "" then
  return "%#StatusLineInfo# " .. text .. " %*"
end
```

`b:db_name` holds the name of the connection, in the sql buffer and its output windows alike, so `%{get(b:, 'db_name', '')}` shows which database you are looking at.

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
