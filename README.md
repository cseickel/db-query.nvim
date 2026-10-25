# db-query.nvim

db-query.nvim runs SQL from Neovim through your database's own command line client: `psql`, `duckdb`, `sqlite3`, `mysql`, or `mariadb`. It is another take on [vim-dadbod](https://github.com/tpope/vim-dadbod), and I wrote it to control how the output is written and where it goes. The client writes the rows straight to a results file that nvim opens, so the size of a result is limited by disk instead of nvim's memory, and with CSV output and [csv-table.nvim](https://github.com/cseickel/csv-table.nvim) that reaches gigabytes. Everything else the client prints goes to a log that fills in while the query runs, and `<C-c>` cancels the query.

A language server built into the plugin completes the tables, columns, and functions of the buffer's database, and gives hover, signature help, goto definition, and references, so you don't need vim-dadbod-completion.

It pairs well with:

- [csv-table.nvim](https://github.com/cseickel/csv-table.nvim), which shows a CSV results file as a table.
- [neo-tree-database.nvim](https://github.com/cseickel/neo-tree-database.nvim), which browses each connection's tables and columns in neo-tree, running its queries through db-query.

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

The first time you run a query, db-query asks which database to use. The list opens through `vim.ui.select`, so you get whatever picker you have configured. A connection is a name and a [vim-dadbod](https://github.com/tpope/vim-dadbod) URL, and the one you pick is stored in `b:db`. New sql buffers reuse the last connection, and `:DBConnect` points a buffer at a different one. Anything else that sets `b:db` will cause db-query to use that connection and bypass the picker.

The list comes from [vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui)'s `connections.json` (in `g:db_ui_save_location`, or `~/.local/share/db_ui`), then from `g:dbs`, so the connections you configured for vim-dadbod show up. Set `connections` to a list, or a function returning one, to read from somewhere else instead:

```lua
opts = {
  connections = function()
    return {
      { name = "warehouse", url = "postgres://app@db.internal/warehouse" },
    }
  end,
}
```

A postgres, mysql, or mariadb connection is tested with `select 1` before the buffer takes it. When the test fails, the buffer is left with no connection, `b:db_name` reads `<name> CONNECTION ERROR`, and the next query opens the picker.

### Environment variables

If you also have vim-dadbod installed, then it will be used to expand environment variables in a URL. This allows you to exclude passwords from your connections file:

```json
[
  { "name": "warehouse", "url": "postgres://app:$PGPASS@db.internal/warehouse" }
]
```

A `$` that is part of a password has to be written `%24`.

### Client-specific options

A mysql, mariadb, or postgres URL can end in client options. `mariadb://app@db.internal/warehouse?ssl-verify-server-cert=0` runs `mariadb --ssl-verify-server-cert=0`, and `psql` reads a postgres URL's options itself.

A `duckdb:` or `sqlite:` URL names a file, as in `duckdb:/home/me/scratch.duckdb`. `duckdb::memory:` and `sqlite::memory:`, or the scheme with no path, open an in-memory database.

### Naming the connection in the file

A comment in the first or last five lines of a file names the connection that file runs against:

```sql
select * from orders;

-- @db-query connection=[rva-3-dev]
```

The name is one from the picker's list. The brackets are needed only when the name has a space in it, and `connection` can be shortened to any prefix, so `c=rva-3-dev` works too.

The comment is read when the file opens and every time it is written, so an edit takes effect when you save. It takes precedence over the last connection you picked. A name missing from the list leaves the buffer with no connection, rather than on some other database. `:DBConnect` in a file with the comment asks before replacing the name in it.

## Commands

| Command                    |                                                         |
|----------------------------|---------------------------------------------------------|
| `:DBQuery`                 | Run the buffer                                          |
| `:DBQueryStatement`        | Run the statement the cursor is in                      |
| `:'<,'>DBQuery`            | Run the selection                                       |
| `:1,20DBQuery`             | Run lines 1 to 20                                       |
| `:DBQuery -f csv`          | Write the results file as CSV                           |
| `:DBQuery -o report`       | Name the results file yourself                          |
| `:DBOutput`                | Switch the output window between log and results file   |
| `:DBOutput log`            | Show the log                                            |
| `:DBOutput result`         | Show the last query's results file                      |
| `:DBOutput close`          | Close the output windows                                |
| `:DBOutput refresh`        | Run the last query again                                |
| `:DBConnect`               | Pick the database for this buffer                       |
| `:DBRefreshCatalog`        | Read this buffer's database catalog again               |
| `:DBRefreshCatalog cancel` | Stop the read of that catalog                           |
| `:DBOutputDir ~/out`       | Set the output directory for the session                |

## Running queries

`:DBQueryStatement` finds the statement by the rules of the buffer's database. A statement ends at a `;` outside a string, a comment, or a function body. On mysql and mariadb a `delimiter` line is honored, so after `delimiter //` the statement under the cursor in a `create procedure` is the whole procedure.

A query writes a results file only when it is a single `select`, `with`, `table`, or `values` statement, or an `insert`, `update`, `delete`, or `merge` with a `RETURNING` clause. Anything else writes only to the log.

`-f csv` writes delimited rows in place of the client's table, to a `.csv` file, or `.tsv` on mysql and mariadb. Pair it with something that renders CSV, like [csv-table.nvim](https://github.com/cseickel/csv-table.nvim).

`-o` names the results file for one query. `-o report` writes `report.txt` or `report.csv` in the working directory, and `-o ~/exports/` writes into that directory under the buffer's own name. The format always sets the extension, so `-o report.csv` on a text query writes `report.txt`. `-o` with no path prompts for one, prefilled with the last path this buffer wrote.

## Output

Every query from a sql buffer appends the client's output to that buffer's log, and the output window shows the log while the query runs. When the query finishes with rows, the window switches to the results file. When it fails or is cancelled, the window stays on the log, with the reason at the bottom.

`:DBOutput` opens the output window if it was closed. You can specify `:DBOutput log` or `:DBOutput result` to switch between outputs. `:DBOutput close` closes every window in the current tab that shows this buffer's log or results file. Every form of `:DBOutput` works from the sql buffer and from the output window.

`:DBOutput refresh` runs the last query again exactly as it ran, with the same sql text, connection, format, and `-o` path, even after you edited the buffer or picked another connection. With `-o`, it writes over the file the last run wrote without asking.

Results files go to `stdpath("cache")/db-query/<pid>/` by default, named for the sql buffer and numbered. Closing the output window keeps the files, and `:DBOutput` brings them back. The log and the results files are deleted when the sql buffer is wiped, and whatever an earlier nvim left behind is swept the next time one starts.

Set `output_dir` to write results files somewhere else. That turns `output_cleanup` off, because a directory you chose is where you keep results. Set `output_cleanup = true` alongside it to have the files deleted with their sql buffer anyway.

`:DBOutputDir ~/exports` writes results files there for the rest of the session, and the plugin never deletes them. `:DBOutputDir` with no argument prompts for a directory, and an empty answer goes back to what `setup` was given.

## Status

While a query runs, a spinner marks its first line of code, and a bar in the gutter extends from that spinner down the rest of the running query lines and wraps to the line below it. That line below the running query shows `running query`, a clock, and the cancel key. When the query finishes, the spinner turns into a mark of the result, which stays until the next query runs or you edit the buffer. Each statement that ran also gets a diagnostic, which stays until a newer run replaces it.

`statusline(buf)` returns the same spinner, label, and clock for your statusline or winbar. It reads `testing connection <name>` while a connection is tested, and `reading catalog <name>` while the buffer's database catalog is read:

```lua
local text = require("db-query").statusline(vim.api.nvim_get_current_buf())
if text ~= "" then
  return "%#StatusLineInfo# " .. text .. " %*"
end
```

`b:db_name` holds the name of the connection, in the sql buffer and its output windows alike, so `%{get(b:, 'db_name', '')}` shows which database you are looking at.

### Highlights

Each status has a group for the mark, a `Band` group for the strip under the query, and a `Text` group for the message on that strip. Every group is set as a default, so one your colorscheme defines is kept. The `Band` and `Text` groups are derived from the status group, so defining the status group alone recolors all three.

| Status    | Group                    | Links to          | Derived groups                                             | Diagnostic |
|-----------|--------------------------|-------------------|------------------------------------------------------------|------------|
| running   | `DbQueryProgress`        | `DiagnosticInfo`  | `DbQueryProgressBand`, `DbQueryProgressText`               |            |
| success   | `DbQueryResultOk`        | `DiagnosticOk`    | `DbQueryResultOkBand`, `DbQueryResultOkText`               | info       |
| failed    | `DbQueryResultError`     | `DiagnosticError` | `DbQueryResultErrorBand`, `DbQueryResultErrorText`         | error      |
| cancelled | `DbQueryResultCancelled` | `DiagnosticHint`  | `DbQueryResultCancelledBand`, `DbQueryResultCancelledText` | hint       |

## Completion

Completion offers only keywords until db-query has read the catalog of the buffer's database, meaning its tables, columns, functions, and types. Depending on the size of your schema and the speed of the database, the first read takes from 1 second to 5 minutes. It runs in the background, and the catalog is saved across sessions, so you probably won't notice the delay after the first connection. See Catalog below.

The language server is named `db-query`. It runs inside nvim and attaches to every `sql`, `mysql`, and `plsql` buffer, with no install and no `vim.lsp.config` entry. Set `lsp = false` to turn it off.

With [nvim-cmp](https://github.com/hrsh7th/nvim-cmp), use the `nvim_lsp` source and, for signature help, [cmp-nvim-lsp-signature-help](https://github.com/hrsh7th/cmp-nvim-lsp-signature-help). nvim-cmp's default comparators sort by item kind and leave `sort_text` out, so add it ahead of `kind` for sql filetypes to keep columns in table order:

```lua
local cmp = require("cmp")
local compare = cmp.config.compare
cmp.setup.filetype({ "sql", "mysql", "plsql" }, {
  sources = {
    { name = "nvim_lsp" },
    { name = "nvim_lsp_signature_help" },
  },
  sorting = {
    comparators = {
      compare.offset,
      compare.exact,
      compare.score,
      compare.sort_text,
      compare.kind,
    },
  },
})
```

[blink.cmp](https://github.com/Saghen/blink.cmp) uses its `lsp` source and sorts by `sort_text` by default, so nothing changes. Set `signature = { enabled = true }` for signature help.

Without a completion plugin, nvim's own completion works:

```lua
vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(event)
    local client = vim.lsp.get_client_by_id(event.data.client_id)
    if client and client.name == "db-query" then
      vim.lsp.completion.enable(true, client.id, event.buf, { autotrigger = true })
    end
  end,
})
```

`K` shows hover and `<C-s>` in insert mode shows signature help, which are nvim's default maps.

Completion offers what the cursor's place in the statement calls for: the columns of the tables in scope, in the table's order, then aliases, CTEs, tables, schemas, keywords, and functions. Typing `.`, `(`, `'`, or `"` triggers it. In an `insert`, it also offers items that write the column list and the values row:

- after `insert into`, one item per table that writes `t (col, ...) values (...)`
- inside the column list, `all columns` while the list is empty, and each column not listed yet
- inside an empty `values (`, one value per listed column

Each value is a placeholder for its column:

```sql
insert into trades (
  id,
  qty,
  note,
  created
) values (
  DEFAULT,
  0,
  NULL,
  current_timestamp
)
```

Inside a string that is compared to, assigned to, or inserted into an enum column, completion offers the values the enum accepts.

Hover on a column, table, or function name shows its type, columns, or overloads, and its comment. Signature help shows every overload of the function under the cursor, and `(` and `,` trigger it.

Goto definition on a table, view, function, or column opens the object's DDL, read from the database. The file is named for the object, such as `public.orders.sql`, and its buffer runs against the same connection. Goto references lists what in the database depends on the object, such as tables whose foreign keys point at it, views, functions, and triggers. A reference built with dynamic sql is not found. The list starts with the object's own definition unless you call `vim.lsp.buf.references({ includeDeclaration = false })`.

Both answer from the catalog, so an object created since the catalog was read is not found until `:DBRefreshCatalog` reads it again.

## Catalog

db-query reads the catalog of each database a buffer connects to, in the background, and saves it under `stdpath("cache")/db-query/catalog/`, in a directory only your user can read, since it lists every table and column. The next session starts from the saved catalog and reads a fresh one behind it. Buffers on the same database share one catalog.

The catalog is read when a buffer takes a connection, after any query holding a statement that starts with `create`, `alter`, `drop`, or `comment`, and on `:DBRefreshCatalog`. Each of its queries is killed after `catalog.timeout`. A read that fails keeps the catalog you had and says why. `:DBRefreshCatalog cancel` stops a read and also keeps the catalog you had.

### catalog.clients

`catalog.clients` replaces the built-in catalog reader of one client, keyed by `postgres`, `mysql`, `mariadb`, `sqlite`, or `duckdb`. The function gets a request and a `done` callback, and may call the built-in reader itself. This one leaves out postgres's own functions:

```lua
require("db-query").setup({
  catalog = {
    clients = {
      postgres = function(request, done)
        require("db-query.client.postgres").catalog(request, function(catalog, err)
          if not catalog then
            return done(nil, err)
          end
          catalog.functions = vim.tbl_filter(function(fn)
            return fn.schema ~= "pg_catalog"
          end, catalog.functions)
          done(catalog)
        end)
      end,
    },
  },
})
```

`request` holds:

- `client`, the client's name.
- `connection`, the resolved url, password included.
- `timeout`, the `catalog.timeout` setting for a built-in reader, and nil for yours.
- `query(statement, opts, callback)`, which runs `statement` read-only through the client and calls `callback(output, err)` with what it printed, one row per line with no header, or with why it failed. `opts` is nil or `{ timeout = milliseconds }`.

Call `done(catalog)` once with a table of the shape `dbquery.Catalog` describes in `lua/db-query/catalog/shape.lua`, or `done(nil, err)` with why there is none. A catalog of another shape is refused with the field that is wrong. `catalog.timeout` does not apply to your function, so the timeouts you pass to `query` are the only ones. A function that never calls `done` keeps the read running until `:DBRefreshCatalog cancel` stops it.

## Parquet

With `parquet = true`, opening a `.parquet` file opens a sql buffer of the same name ending in `.sql`, holding a duckdb query of the first 1000 rows, and runs it with CSV output. The file is loaded as a view, so completion sees its columns without importing the data.

The plugin has to load at startup to open the file, so turn off lazy loading:

```lua
{
  "cseickel/db-query.nvim",
  lazy = false,
  opts = { parquet = true },
}
```

## Options

These are the defaults. Anything you set merges into them.

```lua
require("db-query").setup({
  -- A list of { name, url } tables, or a function returning one, that
  -- replaces the built-in connection list. See Connections.
  connections = nil,

  -- Open a .parquet file as a duckdb query of it. See Parquet.
  parquet = false,

  -- Stops a running query or connection test. It is bound only while one
  -- runs, and it can be changed but not disabled.
  cancel = "<C-c>",

  -- The marks of a finished query. The defaults are Nerd Font glyphs, so set
  -- text or emoji if your font has none.
  icons = { ok = "\u{f058}", failed = "\u{f057}", cancelled = "\u{f05e}" },

  -- Attach the language server to sql buffers. See Completion.
  lsp = true,

  -- The results file format, "text" or "csv". See Running queries.
  format = "text",

  -- Where results files go. See Output.
  output_dir = nil,

  -- Delete results files with their sql buffer. It defaults to false when
  -- output_dir is set. See Output.
  output_cleanup = true,

  catalog = {
    -- Milliseconds a catalog query, or a `read`, may take before its client
    -- is killed.
    timeout = 300000,

    -- Functions that replace the built-in catalog readers. See catalog.clients.
    clients = {},
  },
})
```

## Keys

The only key the plugin binds is `cancel`, and only while a query or a connection test is running, in the sql buffer and in its output windows. Here are some example bindings:

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
end, { desc = "switch between the log and the results file" })
```

`execute` takes `visual`, `range`, `statement`, `format`, and `output`, which is a path for the results file or `true` to be asked for one. `output` takes `"log"`, `"result"`, `"toggle"`, `"close"`, or `"refresh"`, the same as `:DBOutput`.

## describe

`describe` returns the text hover shows for a table, view, or column, as lines of markdown, so a plugin with no sql buffer, such as a database tree, can show it in a float:

```lua
local lines = require("db-query").describe({
  url = vim.b.db,
  relation = { "public", "orders" },
  column = "total",
})
if lines then
  vim.lsp.util.open_floating_preview(lines, "markdown")
end
```

`url` is a connection url as `b:db` holds it. `relation` is the table's or view's name, one part per element, from the database or schema down. `column` is a column of that relation, and leaving it out describes the relation. Each part has to match the catalog's spelling exactly, so `{ "Orders" }` finds nothing when the table is `orders`. A name of one part is looked for in the search path, and then anywhere when a single schema has a relation by that name.

When there is nothing to show, it returns nil and the reason:

| Reason | When |
|---|---|
| `"no connection url"` | `url` is nil or empty |
| `"no client known for <scheme>"` | db-query has no client for the url's scheme |
| `"reading"` | the first read of the database's catalog is running, and the first call for a database starts it |
| `"no catalog"` | that read failed, and `:DBRefreshCatalog` reads it again |
| `"not found"` | the catalog holds nothing by that name |

Call it from nvim's main loop.

## read

`read` runs one statement read-only on a connection url and passes back what the client printed, so a plugin with no sql buffer can query a database. [neo-tree-database.nvim](https://github.com/cseickel/neo-tree-database.nvim) runs every query of its tree this way:

```lua
require("db-query").read({ url = vim.b.db, statement = "select 1" }, function(output, err)
  if not output then
    vim.notify(err, vim.log.levels.ERROR)
  end
end)
```

`url` is a connection url as `b:db` holds it. The callback is called once, on a later tick of the main loop. On success, `output` is what the client printed, one row per line with no header and no alignment. On failure, `output` is nil and `err` says why, such as `"no connection url"`, `"no client known for <scheme>"`, or the client's own error. The client is killed after `catalog.timeout`, and `err` then reads, for example, `"no answer in 300 seconds"`.

## Contributing

[ARCHITECTURE.md](ARCHITECTURE.md) describes how it works. New data adapters are welcome, as are bug fixes. I make no guarantee about new features being accepted, so file an issue first so we can discuss it.
