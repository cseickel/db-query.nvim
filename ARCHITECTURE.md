# Architecture

A query is handed to a cli client, which writes what it prints to a log file and any rows to a results file. nvim opens those files. No result set passes through lua, so what the plugin can handle is bounded by disk rather than by nvim's memory, and with csv export and csv-table that is measured in GBs.

## Modules

All modules are in `lua/db-query/`.

- **Entry points.** `init.lua` is the public API and `setup`, `command.lua` the `:DB*` commands, `parquet.lua` the `*.parquet` hook, and `config.lua` holds the settings. `mainloop.lua` gets code onto nvim's main loop.
- **Running a query.** In `query/`, `source.lua` is the sql buffer and owns its log and the one process it is running. `run.lua` is the query in flight, `process.lua` the client process under it, `log.lua` how its log reads, and `pane.lua` the window showing its output. `selection.lua` captures the lines a query comes from, and `files.lua` names every file the plugin writes and sweeps what earlier nvims left.
- **Showing run status.** `query/status.lua` holds each status's color, icon, and summary, draws the mark a query gets in the sql buffer, and places the extmark that follows a query's lines through edits. `query/progress.lua` draws the mark with a spinner and binds the cancel key while a process runs. `query/result.lua` gives each query the mark and a diagnostic for its last run.
- **Reaching a database.** `connection/init.lua` decides which connection a buffer runs against, helped by `connection/modeline.lua`, `connection/list.lua`, and `connection/dadbod.lua`. `client/init.lua` maps each url scheme to a client and defines `dbquery.Client`, `client/url.lua` reads urls, and `client/query.lua` holds the helpers the catalog, definition, and references queries share. Each database has a folder, `client/postgres/`, `client/mysql/`, `client/sqlite/`, and `client/duckdb/`, whose `init.lua` turns a connection and a statement into a command line, beside its `catalog.lua`, `definition.lua`, and `references.lua`.
- **Reading sql.** `sql/lex.lua` tokenizes, `sql/dialect/` holds one rule set per way of reading sql, and the modules above them say what the cursor is in.
- **Knowing the database.** `catalog/init.lua` keeps one catalog per database and schedules its reads, `catalog/saved.lua` loads and saves the copy on disk, and `catalog/shape.lua` checks what a read returns.
- **Answering the editor.** `lsp/` is an in-process language server for completion, signature help, hover, goto definition, and references.

## A query, end to end

```
:DBQuery on query.sql, a postgres buffer, running  select * from trades;

  init.execute ──► Source:execute ──┬──► Run.start ──► Process.start ──► psql ──┬──► query-1.txt  the rows
       │                            │                                           └──► query.md     the log
       ├─ selection.capture         ├──► Progress.attach    spinner and cancel key in query.sql
       └─ dadbod.resolve            ├──► result.track       forgets earlier marks over the same lines
                                    └──► Pane:display       opens query.md, rereads it every 500ms

  psql exits, and Process calls its subscribers in the order they subscribed:

       1. Run's finish     writes  ✓ 2,520 rows in 0.41s  into query.md
       2. Progress:stop    removes the spinner and the cancel key
       3. result           marks the query with  2,520 rows in 0.41s
       4. Pane             swaps the window from query.md to query-1.txt
```

`Run` subscribes inside `Run.start`, before `Source:execute` attaches the others, so the log is complete on disk before the `Pane` rereads it. A statement that changes the catalog adds one more subscriber, `catalog.refresh`.

`init.execute` captures the selection and the cursor at the moment it is called, because a prompt ends visual mode and an `<expr>` mapping moves the cursor before the plugin may act. What it captures becomes a `dbquery.Context`, the request as the user made it, client included, and every part of the run reads what it needs from `run.ctx`.

The log's closing line and the mark in the sql buffer are both `status.summary`, so they read the same. The row count comes from the file the client's `command` names in `countFile`, which only psql writes, so a mysql or sqlite log closes with `✓ finished in 0.41s`.

## Design decisions

**A buffer runs one process at a time**, a query or a connection test, and starting either cancels the one before it. `query/progress.lua` is the reason: its extmarks and its cancel key are buffer-local, so a second process would draw over the first.

**Plugin code runs on nvim's main loop.** nvim refuses editor changes in a libuv callback (E5560) and under textlock (E565), which holds while it evaluates a statusline, an `<expr>` mapping, or a completion function. Anything entered from outside the plugin goes through `mainloop.lua`, which tests whether nvim would refuse and otherwise waits. Reads are allowed under textlock, so `mainloop.capture` takes the editor state at the call moment and does the rest later. `mainloop.every` is the one timer, and it drops a tick that lands while nvim refuses changes.

**Query rows go to files, never through lua.** Collecting a large result set into a lua string ran nvim out of memory (`E41`). `query/run.lua` has the client write its rows and never reads them back. `client.value` and `client.read` are the exception, for output known to be small: the connection test, the parquet view, the catalog queries, and the DDL that goto definition and references open.

**The client's output is not parsed.** The log holds what the client printed. The results file holds what the client wrote and nothing else.

**Cancelling is a request.** `Process:cancel` asks the server where there is one and sends `SIGINT` where there is not, then leaves the process `running` until the client exits. A replaced query is still running and can still finish, so `Pane` checks that the run it holds is the run it is showing.

**Every file the plugin writes is named by `query/files.lua`,** which also decides which of them the plugin deletes. A results file is deleted with the sql buffer that produced it, and the cache directory an earlier nvim left behind is swept at `setup`. A directory you chose keeps its files until you enable cleanup.

**Reading sql is hand-written, per dialect.** tree-sitter-sql rejects `lateral`, `delete ... using`, `::type[]`, and `tablesample` even in complete statements, and half-typed text parses into ERROR nodes that lose the tables around the cursor. tree-sitter-postgres needs a C compiler or a wasmtime build and replaces only the parse: which relations the cursor can see, what a CTE's columns are, and where `excluded` is in scope are hand-written either way.

**The language server runs in process.** `lsp/init.lua` hands `vim.lsp.start` a `cmd` function in place of a child process, so the server reads the same buffers and the same catalog the rest of the plugin holds, with no ipc and no second copy.

## Connections

`b:db` is what this plugin shares with vim-dadbod and vim-dadbod-completion, and it holds the url as written, which may name a dadbod variable or hold `$PGPASS`. `db#resolve` expands it, and the resolved url is what a client is given, minus any password: a command line is readable by every process on the machine, so `client/postgres/init.lua` puts the password in the environment instead.

A connection from a modeline or the picker is tested with `select 1` before it is stored, so an unreachable host does not block nvim and a query never runs against a connection a pending test may replace. An embedded client, sqlite3 or duckdb, skips the test, because opening the file would create it when it is missing.

## Catalog

`catalog/init.lua` keeps one entry per database, keyed by the url without its password, so two buffers on the same database share one catalog. An entry starts from the copy the last session saved under `stdpath("cache")/db-query/catalog/`, which `catalog/saved.lua` loads and upgrades when its version is behind, and refreshes in the background, so completion has names to offer at once. `get` returns what is known without waiting, and only the first call for a database starts a read, so a read that failed is not retried on every keystroke. A read is replaced, not queued: `refresh` cancels the queries under way and bumps a generation, so a late result is dropped.

Each client's `catalog.lua` reads its own catalog, and `catalog.clients` lets a user replace one. Every such function returns a `dbquery.Catalog`, checked by `catalog/shape.lua`: the search path, the relations with their columns, the functions with their arguments, and the enum types. Names are qualified the way sql has to write them.

## Reading sql

`sql/lex.lua` is the only module that scans sql text, and everything else works on its tokens, so a `;` or a keyword inside a string, a comment, or a function body is never read as code. A `dbquery.Dialect` is the data it lexes by, and one exists per client: which quotes open a string, which words are reserved, which words start a clause, how the server folds an unquoted name, and which client commands the client handles before the server sees them. Reading with the wrong dialect splits statements in the wrong place. `lex.document` lexes a buffer once into a `dbquery.Document`, which every request against that text then reads.

Above the lexer, `sql/statements.lua` says where one statement ends, and the modules from `syntax.lua` to `context.lua` answer what the cursor is in: the clause, the call and argument, the insert target, the string and the column it is compared to (`literal.lua`), and the relations in scope (`relations.lua`). The text is usually half typed, so an open group is closed at the next keyword that starts a clause.

## Language server

`lsp/init.lua` answers completion, signature help, and hover from the catalog and the relations the cursor can see. nvim calls it inside the requester's own call stack, under textlock during completion, so a request is read at once and answered on a later pass of the main loop. Goto definition and references query the database, so their handlers answer once those queries finish. A buffer with no connection still gets keywords and the names its own sql defines.

`lsp/target.lua` turns the word under the cursor into the catalog object it names, for hover, definition, and references alike. `lsp/definition.lua` has the object's client read its DDL, through the client's `definition.lua`, and writes it to the file `files.definition` names, with `b:db` set on the file's buffer. A definition or a reference is then an ordinary file location, and the user can run the DDL. References come from the client's `references.lua`. Postgres reads most of them from `pg_depend`. The rest are `like` searches of the text the database keeps, and `lex.mentions` lexes each hit with the client's dialect and keeps it only where the name is a word or a quoted identifier. A reference is kept only when the catalog holds it, since the DDL reader takes a catalog entry. The DDL reads run four at a time, because each is a client process and, on a server, a connection.

## Adding a database

Create a folder under `lua/db-query/client/` holding `init.lua`, `catalog.lua`, `definition.lua`, and `references.lua`, and map its url scheme to the folder in `CLIENTS` in `client/init.lua`. `init.lua` returns a `dbquery.Client`, the contract in `client/init.lua`, and requires the other three files as its `catalog`, `definition`, and `references` fields. `client/mysql/init.lua` returns two clients, `mysql` and `mariadb`, that differ in the executable they run and the dialect they read by. The parts that need a decision rather than a value:

- `command(spec)` turns a connection and a statement into argv. When `spec.path` is set the client must put the rows there and nothing else, either by writing there itself, by writing to `spec.staging` and returning `staged = true`, or by returning `stdout = spec.path`. With no `spec.path`, everything the client prints goes to the log. A client that can count the rows it wrote returns a `countFile` holding the count, and the log and the mark then read `2,520 rows in 0.41s` instead of `finished in 0.41s`.
- `dialect` decides where `:DBQueryStatement` cuts a statement. Use the closest one under `sql/dialect/`, or derive a new one with `dialect.derive`. A client that runs lines of its own before the server sees them needs a dialect of its own, the way `psql.lua` derives from `postgres.lua`.
- `catalog.lua` reads the catalog, `catalog(request, done)`, using the helpers in `client/query.lua`: `select` and `collect` run queries that print one json object per row, `relations` groups column rows into relations, `qualified` quotes a name the way the dialect does, and `literal` and `containing` build the string literals a search needs.
- `definition.lua` reads the DDL goto definition opens, `definition(request, target, done)`.
- `references.lua` finds what depends on an object, for goto references, `references(request, target, done)`. `query.references` turns the rows of a text search into `dbquery.Reference`s, dropping a hit where the name is only inside a string or a comment.
- `cancel` is worth writing only when the database has a server that can be asked to stop a query, and it needs `command` to return a `sessionFile` the client records its session id in. Without it, cancelling sends `SIGINT`, which is right for an embedded database.
