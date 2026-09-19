# Architecture

A query is handed to a cli client, which writes what it prints to a log file and any rows to a results file. nvim opens those files. No result set passes through lua, so what the plugin can handle is bounded by disk rather than by nvim's memory, and with csv export and csv-table that is measured in GBs.

## Modules

All modules are in `lua/db-query/`.

- **Running a query.** `source.lua` is the sql buffer and owns the one process it is running. `run.lua` is the query in flight, `process.lua` the client process under it, `pane.lua` the window showing its output, and `indicator.lua` the spinner and cancel key drawn in the sql buffer.
- **Reaching a database.** `client/` maps each url scheme to a client and turns a connection and a statement into a command line, one file per client. `connect.lua` decides which connection a buffer runs against, helped by `modeline.lua`, `connections.lua`, `dadbod.lua`, and `url.lua`.
- **Reading sql.** `sql/lex.lua` tokenizes, `sql/dialect/` holds one rule set per way of reading sql, and the modules above them say what the cursor is in.
- **Knowing the database.** `catalog/` keeps one catalog per database, read in the background and saved to disk.
- **Answering the editor.** `lsp/` is an in-process language server for completion, signature help, and hover.
- **Entry points.** `init.lua` is the public API, `command.lua` the `:DB*` commands, `parquet.lua` the `*.parquet` hook.
- **Plumbing.** `main.lua` gets code onto nvim's main loop, `output.lua` names every file the plugin writes, `selection.lua` captures the lines a query comes from, `config.lua` holds the settings.

## A query, end to end

```
:DBQuery on query.sql, a postgres buffer, running  select * from trades;

  init.execute ──► Source:execute ──┬──► Run.start ──► Process.start ──► psql ──┬──► query-1.txt  the rows
       │                            │                                           └──► query.md     the log
       ├─ selection.capture         ├──► Indicator.attach   spinner and cancel key in query.sql
       └─ dadbod.resolve            └──► Pane:display       opens query.md, rereads it every 500ms

  psql exits, and Process calls its subscribers in the order they subscribed:

       1. Run's finish     writes  **✅ 1 finished in 0.412s**  into query.md
       2. Indicator:stop   removes the spinner and the cancel key
       3. Pane             swaps the window from query.md to query-1.txt
```

`Run` subscribes inside `Run.start`, before `Source:execute` attaches the other two, so the log is complete on disk before the `Pane` rereads it. A statement that changes the catalog adds a fourth subscriber, `catalog.refresh`.

`init.execute` captures the selection and the cursor at the moment it is called, because a prompt ends visual mode and an `<expr>` mapping moves the cursor before the plugin may act. What it captures becomes a `dbquery.Context`, the request as the user made it, dialect included, and every part of the run reads what it needs from `run.ctx`.

## Design decisions

**A buffer runs one process at a time**, a query or a connection test, and starting either cancels the one before it. `indicator.lua` is the reason: its extmarks and its cancel key are buffer-local, so a second process would draw over the first.

**Plugin code runs on nvim's main loop.** nvim refuses editor changes in a libuv callback (E5560) and under textlock (E565), which holds while it evaluates a statusline, an `<expr>` mapping, or a completion function. Anything entered from outside the plugin goes through `main.lua`, which tests whether nvim would refuse and otherwise waits. Reads are allowed under textlock, so `main.capture` takes the editor state at the call moment and does the rest later.

**Query rows go to files, never through lua.** Collecting a large result set into a lua string ran nvim out of memory (`E41`). `run.lua` has the client write its rows and never reads them back. `client.value` is the exception, for output known to be small: the connection test, the parquet view, and the catalog queries.

**The client's output is not parsed.** The log holds what the client printed. The results file holds what the client wrote and nothing else.

**Cancelling is a request.** `Process:cancel` asks the server where there is one and sends `SIGINT` where there is not, then leaves the process `running` until the client exits. A replaced query is still running and can still finish, so `Pane` checks that the run it holds is the run it is showing.

**Every file the plugin writes is named by `output.lua`,** which also decides which of them the plugin deletes. A results file is deleted with the sql buffer that produced it, and the cache directory an earlier nvim left behind is swept at `setup`. A directory you chose keeps its files until you enable cleanup.

**Reading sql is hand-written, per dialect.** tree-sitter-sql rejects `lateral`, `delete ... using`, `::type[]`, and `tablesample` even in complete statements, and half-typed text parses into ERROR nodes that lose the tables around the cursor. tree-sitter-postgres needs a C compiler or a wasmtime build and replaces only the parse: which relations the cursor can see, what a CTE's columns are, and where `excluded` is in scope are hand-written either way.

**The language server runs in process.** `lsp/init.lua` hands `vim.lsp.start` a `cmd` function in place of a child process, so the server reads the same buffers and the same catalog the rest of the plugin holds, with no ipc and no second copy.

## Connections

`b:db` is what this plugin shares with vim-dadbod and vim-dadbod-completion, and it holds the url as written, which may name a dadbod variable or hold `$PGPASS`. `db#resolve` expands it, and the resolved url is what a client is given, minus any password: a command line is readable by every process on the machine, so `client/postgres.lua` puts the password in the environment instead.

A connection from a modeline or the picker is tested with `select 1` before it is stored, so an unreachable host does not block nvim and a query never runs against a connection a pending test may replace. An embedded client, sqlite3 or duckdb, skips the test, because opening the file would create it when it is missing.

## Catalog

`catalog/init.lua` keeps one entry per database, keyed by the url without its password, so two buffers on the same database share one catalog. An entry starts from the copy the last session saved under `stdpath("cache")/db-query/catalog/` and refreshes in the background, so completion has names to offer at once. `get` returns what is known without waiting, and only the first call for a database starts a read, so a read that failed is not retried on every keystroke. A read is replaced, not queued: `refresh` cancels the queries under way and bumps a generation, so a late result is dropped.

Each client file holds the function that reads its own catalog, and `catalog.clients` lets a user replace one. Every such function returns a `dbquery.Catalog`, checked by `catalog/shape.lua`: the search path, the relations with their columns, the functions with their arguments, and the enum types. Names are qualified the way sql has to write them.

## Reading sql

`sql/lex.lua` is the only module that scans sql text, and everything else works on its tokens, so a `;` or a keyword inside a string, a comment, or a function body is never read as code. A `dbquery.Dialect` is the data it lexes by, and one exists per client: which quotes open a string, which words are reserved, which words start a clause, how the server folds an unquoted name, and which client commands the client handles before the server sees them. Reading with the wrong dialect splits statements in the wrong place.

Above the lexer, `sql/statements.lua` says where one statement ends, and the modules from `syntax.lua` to `context.lua` answer what the cursor is in: the clause, the call and argument, the insert target, and the relations in scope. The text is usually half typed, so an open group is closed at the next keyword that starts a clause.

## Language server

`lsp/init.lua` answers completion, signature help, and hover from the catalog and the relations the cursor can see. nvim calls it inside the requester's own call stack, under textlock during completion, so a request is read at once and answered on a later pass of the main loop. A buffer with no connection still gets keywords and the names its own sql defines.

## Adding a database

Add a file under `lua/db-query/client/` returning a `dbquery.Client`, and map its url scheme to it in `CLIENTS` at `client/init.lua:51`. `dbquery.Client` at `client/init.lua:37` is the contract. The parts that need a decision rather than a value:

- `command(spec)` turns a connection and a statement into argv. When `spec.path` is set the client must put the rows there and nothing else, either by writing there itself, by writing to `spec.staging` and returning `staged = true`, or by returning `stdout = spec.path`. With no `spec.path`, everything the client prints goes to the log.
- `dialect` decides where `:DBQueryStatement` cuts a statement. Use the closest one under `sql/dialect/`, or derive a new one with `dialect.derive`. A client that runs lines of its own before the server sees them needs a dialect of its own, the way `psql.lua` derives from `postgres.lua`.
- `catalog(request, done)` reads the catalog, using the helpers in `catalog/rows.lua`.
- `cancel` is worth writing only when the database has a server that can be asked to stop a query, and it needs `command` to return a `sessionFile` the client records its session id in. Without it, cancelling sends `SIGINT`, which is right for an embedded database.
