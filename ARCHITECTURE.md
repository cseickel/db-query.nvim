# Architecture

db-query runs each query through the database's own command-line client, such as `psql` or `sqlite3`. The client writes its messages to a log file and its rows to a results file, and nvim opens those files. The rows never pass through lua, so the size of a result set is limited by disk space instead of nvim's memory. With csv output and csv-table.nvim, results of several GB work.

## Modules

All modules are in `lua/db-query/`.

### Entry points

- `init.lua` is the public API and `setup`.
- `command.lua` defines the `:DB*` commands.
- `parquet.lua` opens `*.parquet` files as a duckdb query.
- `config.lua` holds the settings.
- `mainloop.lua` runs code at a moment when nvim allows editor changes. See [Plugin code runs on nvim's main loop](#plugin-code-runs-on-nvims-main-loop).

### Running a query

These are in `query/`.

- `source.lua` exists once per sql buffer. It holds the buffer's log and the one process the buffer is running.
- `run.lua` is one query in flight.
- `process.lua` is the client process behind a run.
- `log.lua` writes each run into the buffer's markdown log.
- `pane.lua` is the split window that shows the log or the rows.
- `selection.lua` reads the lines to run from the buffer.
- `files.lua` names every file the plugin writes, and deletes old ones.

### Showing run status

These are also in `query/`.

- `status.lua` defines the color, icon, and summary text for each status. It draws the mark next to a query, and places the extmark that keeps the mark on the query's lines while you edit.
- `progress.lua` draws a spinner mark while a process runs, and binds the cancel key.
- `result.lua` marks a finished query with how it ended, and adds a diagnostic.

### Reaching a database

- `connection/init.lua` picks the connection a buffer runs against. It uses:
  - `connection/modeline.lua` for the `@db-query` comment in a sql file
  - `connection/list.lua` for the picker's list
  - `connection/dadbod.lua` for vim-dadbod
- `client/init.lua` maps each url scheme to a client, and defines the `dbquery.Client` type.
- `client/url.lua` parses connection urls.
- `client/query.lua` holds helpers for the catalog, definition, and references queries.
- Each database has a folder: `client/postgres/`, `client/mysql/`, `client/sqlite/`, and `client/duckdb/`. Each folder holds:
  - `init.lua`, which builds the command line that runs a statement
  - `catalog.lua`, which reads the catalog
  - `definition.lua`, which reads an object's DDL
  - `references.lua`, which finds what depends on an object

### Reading sql

These are in `sql/`.

- `lex.lua` splits sql into tokens.
- `dialect/` holds one rule set for each kind of sql the plugin reads.
- The other modules work out what the cursor is in. See [Reading sql](#reading-sql-1).

### The catalog

These are in `catalog/`.

- `init.lua` keeps one catalog per database and schedules reads of it.
- `saved.lua` saves each catalog to disk and loads it in the next session.
- `shape.lua` checks that a catalog has the expected shape.

### The language server

`lsp/` is a language server that runs inside nvim. It provides completion, signature help, hover, goto definition, and references.

## A query, end to end

```
:DBQuery on query.sql, a postgres buffer, running  select * from trades;

  init.execute ──► Source:execute ──┬──► Run.start ──► Process.start ──► psql ──┬──► query-1.txt  the rows
       │                            │                                           └──► query.md     the log
       ├─ selection.capture         ├──► Progress.attach    spinner and cancel key in query.sql
       └─ dadbod.resolve            ├──► result.track       clears marks from earlier runs on the same lines
                                    └──► Pane:display       shows query.md unless rows are on screen, rereads it every 500ms

  psql exits, and Process calls its subscribers in the order they subscribed:

       1. Run's finish     writes  ✓ 2,520 rows in 0.41s  into query.md
       2. Progress:stop    removes the spinner and the cancel key
       3. result           marks the query with  2,520 rows in 0.41s
       4. Pane             swaps the window from query.md to query-1.txt
```

`Run.start` subscribes to the process before `Source:execute` adds the other subscribers. That way the log is complete on disk before the pane rereads it. When the statement changes the catalog, `Source:execute` also subscribes `catalog.refresh`.

`init.execute` reads the selection and the cursor position as soon as it is called. It can't wait, because a prompt ends visual mode, and an `<expr>` mapping moves the cursor before the plugin gets to act. What it reads becomes a `dbquery.Context`, which holds the whole request, including the client. Every later step reads from `run.ctx`.

The log's last line and the mark in the sql buffer both come from `status.summary`, so they always match. The row count comes from a `countFile` that the client writes. Only psql writes one, so for the other clients the summary reads `Finished in 0.41s`.

## Design decisions

### A buffer runs one process at a time

The process is either a query or a connection test. Starting a new one cancels the old one. This is because `query/progress.lua` draws its extmarks and binds its cancel key per buffer, so a second process would draw over the first.

### Plugin code runs on nvim's main loop

nvim refuses editor changes in two places:

- inside a libuv callback (E5560)
- under textlock (E565), which is on while nvim evaluates a statusline, an `<expr>` mapping, or a completion function

Any code called from outside the plugin goes through `mainloop.lua`:

- `mainloop.run` checks whether nvim would refuse a change. If it would, `run` waits and tries again.
- `mainloop.capture` reads the editor state immediately, because reading is allowed under textlock. It then passes what it read to `run`.
- `mainloop.every` runs a repeating timer, and skips any tick that lands while nvim refuses changes.

### Rows go to files, never through lua

Reading a large result set into a lua string ran nvim out of memory (`E41`). So `query/run.lua` has the client write its rows to a file, and never reads them back.

`client.value` and `client.read` do read a client's output into lua. They are used only where the output is known to be small:

- the connection test
- the parquet view
- the catalog queries
- the DDL that goto definition and references open
- the public `read` API

### The client's output is shown as it is

- The log holds exactly what the client printed.
- The results file holds exactly what the client wrote.

### Cancelling asks the client to stop

`Process:cancel` asks the database server to stop the query when the client has a way to do that. Otherwise it sends `SIGINT` to the client. Either way, the process stays `running` until the client exits.

When a new query replaces a running one, the old one keeps running until it stops, and it may still finish. So when a run finishes, `Pane` first checks that it is still the buffer's latest run before showing its output.

### `query/files.lua` names every file the plugin writes

It also decides which files the plugin deletes:

- Results in the default cache directory are deleted when the sql buffer that produced them is wiped.
- `setup` deletes the cache directories of nvim instances that have exited.
- Results in the `output_dir` directory are kept, unless `output_cleanup` is on.
- Results in a `:DBOutputDir` directory or at an `-o` path are always kept.

### Reading sql is hand-written for each dialect

The plugin does not use tree-sitter, for these reasons:

- tree-sitter-sql rejects complete, valid statements that use `lateral`, `delete ... using`, `::type[]`, or `tablesample`.
- tree-sitter-sql parses half-typed text into ERROR nodes, which lose the tables around the cursor.
- tree-sitter-postgres needs a C compiler or a wasmtime build.
- tree-sitter-postgres would replace only the parser. The hard parts would still be hand-written: which relations the cursor can see, what columns a CTE has, and where `excluded` is in scope.

### The language server runs inside nvim

`lsp/init.lua` passes `vim.lsp.start` a `cmd` function instead of a program to start. The server reads the same buffers and the same catalog as the rest of the plugin. There is no inter-process communication, and no second copy of the catalog.

## Connections

`b:db` holds a buffer's connection url. vim-dadbod and vim-dadbod-completion read it too. It holds the url as you wrote it, which may name a dadbod variable or contain `$PGPASS`. `db#resolve` expands it into the real url.

The client gets the resolved url with the password removed, because every process on the machine can read a command line. `client/postgres/init.lua` passes the password in the environment instead.

When a connection comes from a modeline or the picker, the plugin tests it with `select 1` before storing it. The test does two things:

- An unreachable host fails the test without blocking nvim.
- While the test is pending, no query runs, so a query never runs against a connection the test may replace.

sqlite and duckdb skip the test, because opening a missing database file would create it.

## Catalog

`catalog/init.lua` keeps one catalog per database. The key is the url without its password, or the file path for sqlite and duckdb. So two buffers on the same database share one catalog.

How the catalog gets filled:

1. The first `get` for a database loads the copy the last session saved under `stdpath("cache")/db-query/catalog/`. `catalog/saved.lua` loads it, and upgrades it when its version is old. Completion can use it immediately.
2. The same call starts a read of the database in the background.
3. `get` returns whatever is known without waiting. Only the first call starts a read, so a failed read is not retried on every keystroke. `:DBRefreshCatalog` retries it.
4. `refresh` replaces a read in progress. It cancels the running queries and increments a generation counter, and any result from the old read is dropped.

Each client's `catalog.lua` reads its own catalog. A user can replace any client's reader with the `catalog.clients` setting. Every reader returns a `dbquery.Catalog`, which `catalog/shape.lua` checks. It holds:

- the search path
- the relations, with their columns
- the functions, with their arguments
- the types, including enums

Each relation, function, and type records its schema. For duckdb, it also records the database, which is one more level of qualification.

## Reading sql

`sql/lex.lua` is the only module that scans sql text, and everything else works on its tokens. So a `;` or a keyword inside a string, a comment, or a function body is never read as code.

The lexer follows a `dbquery.Dialect`, and each client has one. A dialect defines:

- which quotes open a string
- which words are reserved
- which words start a clause
- how the server folds the case of an unquoted name
- which commands the client handles itself before the server sees them, such as psql's backslash commands

Lexing with the wrong dialect splits statements in the wrong places.

`lex.document` lexes a buffer once into a `dbquery.Document`. Every request against that text reuses it.

On top of the tokens:

- `sql/statements.lua` finds where each statement ends.
- The modules from `syntax.lua` to `context.lua` find what the cursor is in:
  - the clause
  - the function call, and which argument
  - the insert target
  - the string, and the column it is compared to (`literal.lua`)
  - the relations in scope (`relations.lua`)

The text is usually half typed. So an open parenthesis that has no match is treated as closed at the next keyword that starts a clause.

## Language server

`lsp/init.lua` answers completion, signature help, and hover from the catalog and from the relations in scope at the cursor. nvim calls the server inside the requester's own call stack, which is under textlock during completion. So the server reads the buffer immediately, and answers on a later pass of the main loop.

Goto definition and references query the database, so they answer once those queries finish.

A buffer with no connection still gets keywords, and the names its own sql defines.

### Which buffer a request is about

`lsp/document.lua` finds the buffer by the request's uri. Another plugin can send a request about a hidden sql buffer, and the server answers it from that buffer's text and `b:db`.

Every unnamed buffer has the uri `file://`. So a request about an unnamed buffer is answered from the current buffer, which is where the editor's own requests come from.

### Finding the object a name refers to

`lsp/target.lua` turns the word under the cursor into the catalog object it names. Hover, goto definition, and references all use it.

`target.named` does the same for a name given in parts, each spelled exactly as the catalog spells it. `describe` in `init.lua` uses it to find a relation or column, then passes it to `hover.markdown`.

### Goto definition

`lsp/definition.lua` asks the client's `definition.lua` for the object's DDL. It writes the DDL to the file `files.definition` names, and sets `b:db` on that file's buffer. The definition is then an ordinary file location, and you can run the DDL from it.

### References

References come from the client's `references.lua`.

- Postgres reads most of them from `pg_depend`.
- The rest come from `like` searches of the source text the database stores, such as function bodies. `lex.mentions` lexes each hit with the client's dialect, and keeps it only where the name is a word or a quoted identifier. A hit inside a string or a comment is dropped.
- A reference is kept only when the catalog holds it, because reading its DDL needs its catalog entry.

DDL reads run four at a time, because each one is a client process, and on a server database each one is also a connection.

## Tests

`test/snapshot/run.lua` runs the snapshot tests:

1. It creates a sqlite and a duckdb database from the schemas in `test/snapshot/cases.lua`.
2. It runs every case against a sql buffer connected to each database.
3. It compares the answers with `test/snapshot/expected/<engine>.txt`.

It needs `sqlite3` and `duckdb` on the path, and skips an engine whose binary is missing.

```bash
nvim --headless -l test/snapshot/run.lua          # prints a diff of each changed case, exits 1 on any difference
nvim --headless -l test/snapshot/run.lua update   # rewrites the expected files from this run
```

Completion snapshots leave out the functions that ship with the database, so upgrading sqlite or duckdb doesn't change them.

## Adding a database

1. Create a folder under `lua/db-query/client/` with `init.lua`, `catalog.lua`, `definition.lua`, and `references.lua`.
2. Map the url scheme to the folder in `CLIENTS` in `client/init.lua`.
3. Have `init.lua` return a `dbquery.Client`, which is defined in `client/init.lua`. It requires the other three files as its `catalog`, `definition`, and `references` fields.

One folder can return more than one client. `client/mysql/init.lua` returns `mysql` and `mariadb`, which differ in the program they run and the dialect they use.

These are the parts of a client that need a decision:

- `command(spec)` turns a connection and a statement into argv.
  - When `spec.path` is set, the rows must end up there, and nothing else may. The client can do this in one of three ways:
    - write to `spec.path` itself
    - write to `spec.staging`, and return `staged = true`. The plugin moves the file to `spec.path`.
    - return `stdout = spec.path`. The shell sends stdout there.
  - When `spec.path` is not set, everything the client prints goes to the log.
  - When the client can count the rows it wrote, return a `countFile` that holds the count. The log and the mark then read `2,520 rows in 0.41s` instead of `Finished in 0.41s`.
- `dialect` decides where `:DBQueryStatement` splits statements. Use the closest one in `sql/dialect/`, or derive a new one with `dialect.derive`. A client that handles some lines itself before the server sees them needs its own dialect, the way `psql.lua` derives from `postgres.lua`.
- `catalog(request, done)` in `catalog.lua` reads the catalog. It uses these helpers from `client/query.lua`:
  - `select` and `collect` run queries that print one json object per row.
  - `relations` groups column rows into relations.
  - `qualified` quotes a name the way the dialect does.
  - `literal` and `containing` build the string literals a search needs.
- `definition(request, target, done)` in `definition.lua` reads the DDL that goto definition opens.
- `references(request, target, done)` in `references.lua` finds what depends on an object, for goto references. `query.references` turns the rows of a text search into `dbquery.Reference`s, and drops any hit where the name is only inside a string or a comment.
- `cancel` is needed only when the database has a server that can be asked to stop a query. It also needs `command` to return a `sessionFile`, where the client records its session id. Without `cancel`, cancelling sends `SIGINT`, which is correct for an embedded database.
