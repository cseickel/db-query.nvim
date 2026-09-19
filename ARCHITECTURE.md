# Architecture

A query is sent to a cli client, which writes what it prints to a log file and any rows to a results file, and those files are opened in a window. This keeps large result sets out of lua memory and off the nvim thread. When paired with exporting to csv and opening it with csv-table, the size of the result set that we can effectively handle is measured in GBs.

## Modules

All modules are in `lua/db-query/`.

Config:

- `config.lua` holds what `setup` was given, merged with the defaults.

Entry points:

- `init.lua` is the public API: `setup`, `execute`, `connect`, `output`, `outputDir`, `refreshCatalog`, `cancelCatalog`, and `status`. Keymaps can call it directly. `setup` also attaches the language server to each sql buffer.
- `command.lua` registers `:DBQuery`, `:DBQueryStatement`, `:DBConnect`, `:DBOutput`, `:DBOutputDir`, and `:DBRefreshCatalog`, and parses their `-f` and `-o` arguments into what `init.lua` takes.
- `parquet.lua` turns a `*.parquet` being opened into a duckdb query against it.

Objects that make up a running query:

- `process.lua` is the client process: how it was started, how it ended, who is told when it does, and how to cancel it. A query and a connection test are each one of these.
- `run.lua` is the query in flight: the log and results file it is writing, and the process writing them.
- `pane.lua` is the window showing one of those files.
- `indicator.lua` is the bar, spinner, label, clock, and cancel key drawn in the sql buffer while a process runs. `Indicator.format` is the spinner, label, and clock as one line for a winbar or statusline, which a catalog read shows through it too.
- `source.lua` is the buffer queries are run from. It connects the run, indicator, and pane, holds the one process the buffer is running, remembers the files its runs have written, and deletes them when the buffer is wiped.

The catalog of each database, read in the background, which the language server answers from:

- `catalog/init.lua`, required as `db-query.catalog`, keeps one catalog per database, starting from the one the last session saved to disk, and reads it through the client's built-in `catalog` function or the one `catalog.clients` names. `get` returns what is known, `refresh` reads again, `cancel` stops a read, and `reading` says how long one has been running. "Catalog" below describes it.
- `catalog/shape.lua` defines `dbquery.Catalog` and checks that a catalog a function returned has that shape.
- `catalog/rows.lua` holds what the built-in functions share: running several queries at once, reading one json object per line, grouping column rows into relations, and reading the labels out of an `enum('a', 'b')` type.

The language server, which "Language server" below describes:

- `lsp/init.lua`, required as `db-query.lsp`, is the server nvim's lsp client talks to, and `attach` starts it for a buffer.
- `lsp/document.lua` reads the buffer a request is about and resolves its connection to a dialect and catalog.
- `lsp/names.lua` matches the names sql writes against the catalog and the relations in scope, and spells a catalog name the way sql has to write it.
- `lsp/complete.lua` builds the completion items for a cursor context, `lsp/insert.lua` the items that write an insert's column list and values row, and `lsp/literal.lua` finds the enum values a string at the cursor may hold.
- `lsp/signature.lua` builds signature help, and `lsp/hover.lua` the hover text.

Everything else is helper functions:

- `main.lua` is where code entered from outside the plugin, a process exiting, a timer tick, a `vim.ui` choice, or a public function, waits until nvim allows editor changes. "Design Decisions" below describes it.
- `selection.lua` captures the lines a query comes from, which may be a range, the visual selection, the whole buffer, or the buffer and cursor row for the statement at the cursor, and later turns them into the sql to run.
- `sql/init.lua`, required as `db-query.sql`, reads enough of a statement to say whether it returns rows and whether it may change the catalog, finds the statement around the cursor if that selection was requested, and finds the mysql `delimiter` command in effect above it.
- `sql/dialect/` holds one `dbquery.Dialect` per way of reading sql: `standard`, `postgres`, `psql`, `sqlite`, `duckdb`, `mysql`, and `mariadb`. Every module under `sql/` reads by the dialect it is given. "Dialects" below describes them.
- `sql/lex.lua` splits sql into tokens by a dialect's rules. Everything that reads sql reads its tokens.
- `sql/statements.lua` says where one statement ends and the next begins.
- `sql/syntax.lua`, `sql/role.lua`, `sql/scope.lua`, `sql/columns.lua`, `sql/body.lua`, and `sql/context.lua` say what the cursor is in, for completion, hover, and signature help. "Reading sql" below describes them.
- `connect.lua` decides which connection a sql buffer runs against, from its modeline, the picker, or the `g:db` the last pick set, and tests each new one before storing it.
- `modeline.lua` reads and rewrites the `-- @db-query connection=[name]` comment.
- `dadbod.lua` holds the calls into vim-dadbod and vim-dadbod-completion: resolving a written url, and pointing completion at a buffer's new `b:db`.
- `connections.lua` provides the list of connections that the database chooser offers.
- `url.lua` pulls the scheme, file path, password, and query parameters out of a dadbod url.
- `client/init.lua`, required as `db-query.client`, maps each url scheme to its client, and through it turns a connection and a statement into a command line, says which kinds of rows the client can write to a file, and names the dialect it reads sql by. `client.value` starts a statement whose result comes back to lua, which the connection test, the catalog, and `parquet.lua` use. Each client is a file beside it: `client/postgres.lua`, `client/sqlite.lua`, `client/duckdb.lua`, and `client/mysql.lua`, which builds both mysql and mariadb. Each holds the built-in function that reads its database's catalog.
- `output.lua` names the log, the results file, the staging file, and the file a database's catalog is saved in, and decides which files the plugin deletes.

## Example Execution

```
  :DBQuery ──┐
             ├──► init.execute ──► Source.of(buf):execute ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐
  a keymap ──┘         │                    │                                            ╎
                       ▼                    ├──► Run        log and results file         ╎
                   db#resolve               │    └──► Process   cli client process       ╎
                                            │            Process:onFinish() ◄╌╌subscribe╌╌┤
                                            ├──► Indicator  spinner / timing display ╌╌╌╌┤
                                            └──► Pane       window with log, then rows ╌╌┘
```

1. `command.lua` parses the arguments and calls `require("db-query").execute`. A keymap calls `execute` with the same options table.

2. `M.execute` in `init.lua` prepares the query:

    - `selection.capture(opts)` returns the lines the query comes from, and for `:DBQueryStatement` the whole buffer with the cursor row. It runs inside `main.capture`, at the moment `execute` is called, because a `vim.ui` prompt ends visual mode and the selection goes with it, and because the keys an `<expr>` mapping returns move the cursor before nvim allows the plugin to change anything. When every line is blank, the query is refused here, before any prompt.
    - When `-o` was given without a path, `vim.ui.input` asks for one, prefilled with `b:db_last_output_path`.
    - When `connect.testing` names a connection test still pending for the buffer, the query is refused, so it never runs on the connection that test may replace.
    - `dadbod.resolve` expands `$VAR` in `b:db` through `db#resolve`. When the buffer has no connection, `connect.pick` asks for one and the rest continues in its callback.
    - `client.dialect(resolved)` returns the dialect the connection's client reads sql by, and `selection.text(capture, dialect)` returns the sql and its `span`, the first and last line it came from. The statement at the cursor is found here rather than at capture, because where a statement ends depends on the dialect: a `\'` inside a mysql string keeps the string open, and in postgres it closes the string. When the buffer lines above the sql leave a mysql `delimiter` other than `;` in effect, the command that set it is put ahead of the sql, so the client ends the statement where the buffer does. When the statement comes back empty, which happens when the cursor sits between statements, the query is refused with "no query to run".
    - `Source.of(buf):execute(ctx)` starts the work. The `dbquery.Context` holds the request as it stood when the user ran it, the dialect included, and every part of the run reads what it needs from `run.ctx` rather than being handed it.

3. `Source:execute` calls `Run.start` and stops there when it returns nil, records the results file in `self.files`, then replaces what the buffer was running: it cancels the previous process, stops its indicator, attaches an `Indicator` to the new process, and calls `Pane:display`. The indicator and the pane subscribe to the process after the run's own subscriber, so the rows are on the results path and the status line is in the log before the pane reads either.

4. `Run.start` decides where output goes and starts the client:

    - `output.log(srcName)` returns the buffer's log under the cache directory, creating it if needed.
    - `sql.rowKind(ctx.dialect, ctx.sql)` returns `"query"`, `"returning"`, or nil.
    - `client.target(resolved, kind, format)` returns the results file extension when the client writes that kind of rows to a file, and nil otherwise. With nil there is no results file, and a `-o` path draws a warning that nothing will be written to it.
    - `output.path(srcName, extension, chosen)` names the results file and creates it empty. `output.staging(extension)` names a file in the cache directory, with no whitespace in its path, for a client that cannot write to the results path itself.
    - `client.command(spec)` returns the argv, env, stdin, and where the client records its server session, plus either `stdout`, a file the shell must catch stdout in, or `staged`, meaning the client wrote to the staging file.
    - `announce` appends the run's heading and sql to the log and opens the block the client's output lands in, so the pane has something to show before the client prints anything.
    - `writingTo` wraps the argv in `sh -c`. Both streams append to the log, unless the command named a `stdout` file, in which case stdout goes there and only stderr reaches the log. `Process.start` runs it through `vim.system`, detached, and the run subscribes `finish` to the process before anything else can.

5. When the client exits, `Process` moves onto the main loop through `main.run`, sets `result` and `status`, removes the session file, and calls every subscriber in the order they subscribed. `status` is `ok` when the exit code is 0 and no signal ended the client, `cancelled` when a cancel was asked, and `failed` otherwise. Each subscriber is called in a `pcall`, so that one throwing cannot stop the rest. The run's `finish` moves a staged file onto the results path when the run succeeded and appends the status line, `**✅ 1 finished in 1.234s**`.

6. `Indicator:stop` removes the bar and the cancel key. `Pane` opens the results file when the process's status is `ok` and the run produced one, and otherwise reloads the log so its status line shows.

## Design Decisions

**A buffer runs one process at a time**, a query or a connection test, and starting either cancels the one before it. The reason is `indicator.lua`: the bar, the extmarks, and the cancel key are buffer-local, so a second process would draw over the first and take its key. `source.lua` is where this rule is kept. A query asked for while a test is pending never reaches it, because `init.execute` refuses the query, as "Connections" describes.

**Plugin code runs on nvim's main loop, where editor changes are allowed.** nvim refuses them in a libuv callback (E5560) and under textlock (E565), which holds while it evaluates a statusline, an `<expr>` mapping, or a completion function. Code entered from outside the plugin goes through `main.lua`, and the code behind it calls vim directly. The entries are the exit callback in `Process.start`, the indicator, pane, and catalog timers, the `vim.ui.select` and `vim.ui.input` callbacks, the catalog's 2 second notice and its `done`, the language server's `request`, and every public function in `init.lua`. `main.run(fn, ...)` calls `fn` now unless nvim refuses changes, and otherwise schedules it and checks again on a 10 ms timer while it is still refused. `wrap(fn)` returns a function that calls `run`. `capture(read, act)` calls `read` at once, since reading is allowed under textlock and waits only for a libuv callback, then calls `act` through `run` with what `read` returned, which is how `execute`, `connect`, `output`, `refreshCatalog`, and `cancelCatalog` take the selection, cursor, or current buffer as they stand when called. `frame(fn)` is the callback of a repeating timer: it schedules one tick, drops ticks that arrive while that one waits, and drops a tick nvim refuses, since the next tick replaces it.

Whether nvim refuses is tested before the call rather than caught after it, because an entry point changes its own state before the first call nvim would refuse. `vim.in_fast_event()` reports a libuv callback. No api reports textlock, and `vim.fn.state()` and `nvim_get_mode().blocking` show nothing under it on nvim 0.12.5, so `refused` edits a hidden scratch buffer inside a `pcall`, with `modifiable` set on the buffer so that `nvim -M` does not read as a lock. The retry runs on a timer rather than through `vim.schedule`, because a scheduled callback runs in the same pass over nvim's event queue. While an `<expr>` mapping waits in `getcharstr`, scheduled callbacks run with textlock still held, so a retry through `vim.schedule` would repeat forever without nvim reading the key that lifts the lock.

Two things stay outside `main.lua`. `status`, `catalog.get`, and `catalog.reading` return a value inline, so they cannot wait, and are called only from the main loop, which a statusline always is. `parquet.lua` schedules the query it opens from `BufReadCmd`, because `BufReadCmd` refuses opening a window and allows the buffer edit the probe makes, so `main.run` would run it at once.

**`process.lua` and `run.lua` read no buffers and open no windows.** A Process holds the job and how it ended, `Process:onFinish` registers a callback, and a Process with no callbacks is fine. A Run adds the log and results file. `parquet.lua` runs its `create view` through `client.value` with nothing drawn.

**Cancelling is a request.** `Process:cancel` queries the server through a second connection where there is one (`pg_cancel_backend`) and sends `SIGINT` where there is not, then leaves the process `running` until the client actually exits, when the status becomes `cancelled`. So a query that has been replaced is still running and can still finish. `Pane` compares `self.run == run` before touching the window, and `Pane:stop` disconnects it from a run it no longer shows.

**Query rows go to files, never through lua.** Collecting a large result set into a lua string through `vim.system` ran nvim out of memory, which shows as `E41`. So `run.lua` has the client write its rows to a file and never reads that file. `client.value` runs a statement in the `value` format and leaves its stdout on the process for the caller, and is used only for output known to be small: the connection test's `select 1`, the parquet view's `create view`, and the catalog queries, whose output on the largest database seen is about 6 MB.

**The client's output is not parsed.** What is in the log is what the client printed, inside the run's output block. The results file holds what the client wrote and nothing else.

**The client writes its own rows where it can.** psql, sqlite3, and duckdb are told the results path and write rows there themselves, which leaves stdout and stderr both free for the log, so command tags, timing, and errors arrive in the order the client printed them. mysql and mariadb have no such mechanism, so the shell catches their stdout in the results file and only stderr reaches the log.

**One log per sql buffer, appended.** Every run of a buffer writes to the same log, always under the cache directory, whatever the output directory is. A cancelled query keeps writing while its replacement is already appending to the same file, so each run has a number that appears in both its heading and its status line.

**A failed run keeps its results file.** Two runs pointed at the same `-o` path share it, so deleting the file on failure would take the other run's output with it. The log holds the reason the run failed.

**Output files are ordinary buffers.** `Pane:show` lists the buffer and leaves `bufhidden` alone, so closing the window keeps the file and `:DBOutput` can bring it back. `Source:close` deletes the log and every results file `output.owns` when the sql buffer is wiped, which is what lets you move between the log and the rows as often as you like.

## The log and the results file

Every run appends to the log. A run also writes a results file when `sql.rowKind` finds rows and `client.target` says the client files that kind.

`sql.rowKind` looks at a single statement, read by the connection's dialect. It reads the tokens `sql.lex` produces, so a `;` or a keyword inside a string, a comment, or a dollar-quoted body counts for nothing. Text that holds a second statement returns nil. So does text that holds a client command, such as psql's `\gset` or `\x`, which cannot go inside COPY, or mysql's `\G`, whose vertical output is not rows. A mysql `delimiter` line changes nothing about the rows, so it is skipped over. Otherwise the first word decides:

- `select`, `with`, `table`, and `values` are `"query"`. A `with` holding the word `insert`, `update`, `delete`, or `merge` anywhere returns nil, because Postgres refuses a data-modifying CTE inside COPY.
- `insert`, `update`, `delete`, and `merge` that mention `returning` are `"returning"`.
- Any other statement, such as `create table` or an `update` without RETURNING, returns nil. The client prints its command tag and row count to the log.

`client.target` returns the extension: the client's `delimited` (`csv`, or `tsv` for mysql and mariadb) for csv format, and `txt` for text format.

How each client fills the results file:

- psql runs a script on stdin. `\o 'path'` sends query output to the file, the statement runs either wrapped in `COPY (...) TO STDOUT WITH (FORMAT csv, HEADER)` for csv or as written for text, and `\o` sends output back to stdout. The same script first sends `SELECT pg_backend_pid()` to `sessionFile` for cancelling.
- sqlite3 takes `.mode csv` or `.mode box`, `.headers on`, and `.output "path"` as `-cmd` arguments. The double quotes are what let `.output` take a path with a space in it.
- duckdb has two routes because neither does everything. `COPY (...) TO 'path' (FORMAT csv, HEADER)` reaches a path containing a space but its argument must be a select, so it is used for csv `"query"` rows. `.output` takes any statement but splits its argument on whitespace and reads quotes as part of the name, so every other case sends `.output` to the whitespace-free staging file and returns `staged = true`. `finish` moves that file onto the results path when the run succeeded and removes it otherwise.
- mysql and mariadb are one client, built by `client(binary)` in `client/mysql.lua`, and differ only in the binary run. The statement goes on stdin, where the client reads it as a script and acts on a `delimiter` line. Neither has a client-side redirect, so `command` returns `stdout = spec.path` and the shell catches stdout there, with `--batch` for csv, which prints tab-separated rows in place of the ascii table. Their `rows` holds only `"query"`, so a RETURNING statement goes to the log.

Without a results file, psql runs with `-e` and `\timing on` so the log labels each statement's row count and elapsed time. sqlite3 and duckdb take the statement on their command line, and mysql and mariadb still read it from stdin.

`Pane:display` shows the log the moment the run starts, with the cursor on the last line, and rereads it every 500ms. A window already holding a results file keeps it instead, so a rerun does not take away what you were reading. When the run finishes it stops the timer and shows the results file when the status is `ok` and there is one, and the log otherwise. `Source:output(view)` is what `:DBOutput` calls, and it reopens the window if it was closed. `"toggle"` picks whichever of the two files is not showing.

## Connections

`b:db` is what this plugin shares with vim-dadbod and vim-dadbod-completion. Two forms of the url are in play:

- The written form, which may hold `$PGPASS` or be the name of a dadbod variable. `b:db` on the sql buffer holds it, and `Pane:show` copies it onto the output buffer, so completion reads the same url in both windows.
- The resolved form from `db#resolve`, which is what the client is given. `url.withoutPassword` takes any password out of it and `client/postgres.lua` puts that password in the environment instead, because a command line is readable by every process on the machine.

A password is written in either of two places, the credentials before the last `@` or a `password` query parameter, and `url.withoutPassword` takes both out. It returns the parameter over the credentials, because that is the one libpq authenticates with, and `?password=` on its own means no password. This matters most for postgres, where psql is handed the whole url and would otherwise show the parameter in `ps` to every user on the machine.

Two grammars are in play, and mixing them lets a password through. psql gets its url whole, so libpq is what parses it: no fragment, `&` as the only separator, percent-escapes and nothing else. `url.withoutPassword` reads the query that way and leaves every parameter it keeps byte for byte, so what psql receives is what was written minus the password. mysql and mariadb take flags instead, so `arguments` in `client/mysql.lua` splits the url up with `url.query`, which follows dadbod: a fragment goes with the query string, `&` and `;` both separate, `+` in a value is a space, `?compress` with no value becomes `--compress=1`, and a parameter with an empty name is dropped. Each parameter that comes back becomes `--key=value` on the command line. Both paths recognize the `password` name decoded, so `?%70assword=` cannot walk a password onto the command line. sqlite and duckdb urls hold a file path, which `url.filePath` returns whole.

`connect.lua` decides what goes in `b:db`. A buffer takes its connection from its modeline when it has one, and otherwise from `g:db`, which only the picker sets. A connection from the modeline or the picker is tested before it is stored, by running `select 1` through `client.value` with a 10 second timeout, so nvim stays responsive while an unreachable host is tried. `Source:test` shows the test with an indicator labelled `testing connection <name>`, on the modeline row when the buffer has one, otherwise on the statement at the cursor, read by the connection's dialect, and otherwise on the cursor's row. The indicator's cancel key cancels the test, and a cancelled test fails the way one the server refused does. One that answers goes in `b:db` and `b:db_name`, `dadbod.refetch` calls `vim_dadbod_completion#fetch`, and `catalog.refresh` starts reading the database's catalog. That plugin records a buffer's database at `FileType`, when a modeline buffer's `b:db` is still empty and it falls back to `g:db`, and keeps it. Its `fetch` reads `w:db`, `t:db`, `b:db`, and `g:db` from the current window and buffer rather than the buffer it is given, so `refetch` runs it inside `nvim_buf_call`. One that fails clears `b:db`, sets `b:db_name` to `<name> CONNECTION ERROR`, and shows `Process:reason`, which is `cancelled`, `no answer in 10 seconds` when the timeout killed the client, what the client printed to stderr, or its exit code and signal when it printed nothing. `g:db` is copied into new buffers untested, because only a connection that answered is ever put there. A client marked `embedded` in its file under `client/`, sqlite3 or duckdb, passes without a test, because opening the file would create it when it is missing and fail when another duckdb process holds its lock.

Each buffer keeps only its latest test, so a slow one that finishes after the user chose something else is dropped: `Source:test` cancels the process of the test before it, and `assign` checks that its test is still the buffer's latest before it touches `b:db` or reports a failure, so a replaced test is cancelled without a notification. `follow` cancels a pending test when it drops it, which happens when the modeline names a connection missing from the list or goes back to the one already in `b:db`. Until the latest one finishes, `b:db` still holds the connection it may replace, so `execute` refuses a query in that time. Queuing the query instead would let several pile up behind one test, and when that test failed each of them would open its own picker.

`dadbod.resolve` returns nil for an empty `b:db` rather than handing it to `db#resolve`, which would resolve it to `w:db`, `t:db`, `g:db`, or `$DATABASE_URL`. A buffer whose modeline connection failed has an empty `b:db`, and a query from it has to open the picker rather than run against a database the modeline never named.

The modeline is read on `FileType` and `BufWritePost`. The `FileType` handler reads it before it would copy `g:db`, so a buffer with a modeline never holds `g:db`'s url. `:DBConnect` in a buffer whose modeline names another connection rewrites the modeline after a confirm, and leaves `g:db` alone.

`connections.list` offers the `connections` setting when there is one, and otherwise vim-dadbod-ui's `connections.json` followed by `g:dbs`. Names already used are skipped, so neither source hides the other's entries.

## Catalog

`catalog/init.lua` keeps one `dbquery.CatalogEntry` per database, keyed by the url without its password, or by the scheme and file path for sqlite and duckdb, so two buffers on the same database share one catalog and a password change does not make a second one. An entry holds the last catalog read, the queries of the read under way, when that read started, and a generation counter.

`catalog.get(connection)` returns the entry's catalog, or nil when none has been read. The first call for a database creates its entry, holding the catalog the last session saved for that key, and starts a read, so a saved catalog is there at once and a fresh one replaces it when the read finishes. No later call starts a read, so a read that failed is not repeated on every call: the entry keeps what it has until something calls `refresh`.

`catalog.refresh(connection)` starts a read and replaces the one under way. It cancels that read's queries, and bumps the generation, so a result or a query callback from the replaced read is dropped when it arrives. For a sqlite or duckdb file that does not exist, it stores an empty catalog without a read, because opening a missing file read-only fails and the database holds nothing until something creates it. Otherwise it records the start time on the entry, builds a `dbquery.CatalogRequest`, and calls the catalog function with it and a `done` callback:

- `client`, the client's `name`.
- `connection`, the resolved url.
- `timeout`, the `catalog.timeout` setting for a built-in function, and nil for one from `catalog.clients`, which sets its own.
- `query(statement, opts, callback)`, which runs `statement` through `client.value` with `readonly = true` and `opts.timeout`, records the process on the entry so a later `refresh` can cancel it, and calls `callback` with the process's stdout when its status is `ok` and otherwise with nil and `Process:reason`. After the read is replaced or finished, `query` does nothing.

`done(catalog, err)` counts only the first time and only for the current generation. It cancels any query still running. The read fails when `err` is set, when `catalog` is nil, or when `shape.problem(catalog)` finds a field of the wrong type. A failed read keeps the catalog from before it and notifies with the key, the problem, and `:DBRefreshCatalog retries`. A read that succeeds stores the catalog, notifies with the key and the seconds it took, and saves the file described under "The saved file". An error thrown by the catalog function, or by a query callback, which runs long after the function returned, is caught and fails the read the same way. A function from `catalog.clients` may call `done` from a libuv callback, where `vim.notify` and the `vim.fn` calls `save` makes are refused, so `done` is wrapped in `main.wrap`.

`catalog.timeout` reaches a built-in function as `request.timeout`, and the function passes it to each of its queries. That is the only place it applies. A function from `catalog.clients` gets `request.timeout = nil` and sets its own through `opts.timeout`, so one that never calls `done` leaves the read running until `refresh` or `cancel` ends it. That is intended: the read is hung, and the spinner says so.

Three things call `refresh`:

- `connect.lua`, when a connection test answers. A sqlite or duckdb connection answers without a test, so its catalog is read as soon as the buffer takes it.
- `Source:execute`, when the process finishes, for a query where `sql.defines` finds a statement starting with one of the dialect's `definitions`, such as `create` or `drop`. It runs whatever the exit status, because a script that failed or was cancelled may have run its definitions before it stopped.
- `:DBRefreshCatalog`, which is `require("db-query").refreshCatalog(buf)`, for the buffer's `b:db`.

`catalog.cancel(connection)`, which `:DBRefreshCatalog cancel` reaches through `require("db-query").cancelCatalog(buf)`, stops the read under way for the buffer's database: it cancels the read's queries, bumps the generation so a `done` that arrives later is dropped, clears the start time, and notifies. The catalog from before the read stays. With no read running it warns and changes nothing.

### Showing a read

While `entry.started` is set on any entry, a module timer in `catalog/init.lua` redraws every statusline and winbar each `Indicator.FRAME_TIME`, 80 ms, through `main.frame`, and stops when the last read ends. A read still running `NOTICE_AFTER` milliseconds, 2 seconds, after it started notifies with `reading the catalog of <key>`.

`catalog.reading(connection)` returns the seconds the read of that database has been running, or nil. It takes a function returning the resolved url rather than the url itself, and calls it only when some read is running, because a statusline evaluates on every redraw and `db#resolve` is a vimscript call. `init.status(buf)` builds on it: a query or connection test in the buffer shows first, through `Source.status`, and otherwise the read of the buffer's database shows as `reading catalog <b:db_name>` with the clock. `status` keeps the resolved url of each `b:db` it has seen in a module table, so a redraw resolves each written url once. `Indicator.format(label, seconds)` produces that line, and `Indicator:status` uses the same function for a process, so both double any `%` in the label, which the statusline would otherwise read as a format item. The spinner frame comes from the elapsed time, so a statusline and a virtual line for the same seconds show the same frame.

### The saved file

`output.catalog(key)` returns `stdpath("cache")/db-query/catalog/<sha256 of key>.json`, creating the directory with mode `0700`, since the file lists every table, column, and comment of a database. The key is the entry's key, so the file name holds no password and the same database from two sessions maps to one file.

The file is a `dbquery.SavedCatalog`, `{ version, catalog }`. `VERSION` in `catalog/init.lua` is 1, and every change to `dbquery.Catalog` raises it. `load(key)` runs when an entry is first created and returns the saved catalog or nil, and with nil the entry starts with no catalog. It returns nil for a file that is not json, has no numeric `version`, or has a version above `VERSION`. A version below `VERSION` is stepped up one at a time through `UPGRADES`, a table keyed by the version a step upgrades from. A version with no step, or a step returning nil, throws the file away, which is the path for a shape change that needs data only a fresh read has. The upgraded catalog then has to pass `shape.problem`, like a catalog a function returned. `UPGRADES` is empty while `VERSION` is 1.

`save(key, catalog)` encodes the file in a `pcall`, writes it to `<path>.<pid>`, checks the write and the close, and renames it onto `<path>`, so two nvims saving the same database at once never leave a mixed file, and a save that fails at any step removes its partial file, leaves the old saved file, and notifies with the error. `output.sweep()` at `setup` removes a `<hash>.json.<pid>` whose pid is no longer running, for an nvim killed mid-save.

### The shape

`dbquery.Catalog`, in `catalog/shape.lua`, is what every catalog function returns:

- `searchPath`, the schemas an unqualified name is looked for in, in order. Each is `{ database?, schema }`.
- `relations`, one per table, view, materialized view, foreign table, or virtual table, with `columns` in the relation's column order. A column has its `type`, `nullable`, `default`, `generated` (`identity`, `stored`, `virtual`, or nil), `hidden`, the `labels` of an enum column, and its `comment`.
- `functions`, one per overload, with `args` in declared order, each with a `mode` (`in`, `out`, `inout`, `variadic`, or `table`) and whether a call may leave it out, `returnsSet` when the function can stand in `from`, and its `result` type.
- `types`, with the `labels` of an enum.

Names are qualified the way the sql writes them. `schema` is the qualifier directly left of a name, and `database` is the one left of `schema`, which only duckdb has. A sqlite function has no schema.

### The built-in functions

Each client file holds a `catalog` function that reads the catalog through `rows.collect`, which runs its queries at once, each with `request.timeout`, and calls back with the decoded rows of all of them or the first error. Every query prints one json object per row, so no value is long enough for a server to truncate the way mariadb's `group_concat_max_len` truncates an aggregated document. A relation's columns come one per row, and `rows.relations` groups adjacent rows with the same database, schema, and name.

- postgres reads relations from `pg_class`, `pg_attribute`, and `pg_attrdef`, leaving out partitions, since a query names the table they belong to, and the `pg_toast` and `pg_temp` schemas. Functions come from `pg_proc`, with the argument names, modes, and types, `pronargdefaults` marking the last passed arguments as having a default, and `proretset`. Types come from `pg_type` with the labels from `pg_enum`, leaving out array types and the row type every table gets. The search path is `current_schemas(true)`.
- mysql and mariadb read relations from `information_schema.tables` and `columns`. A column's `generated` comes from `extra`, `INVISIBLE` there makes it hidden, and enum labels are parsed out of `column_type`. Functions come from `routines` and `parameters`, which hold stored routines only, since the server's own functions are in no table. A function and a procedure may share a name, and with it a specific name, so parameters are matched by routine type too. The search path is `database()`.
- sqlite reads relations from `pragma_table_list` joined to `pragma_table_xinfo`, leaving out shadow tables, `sqlite_` tables, and a relation `pragma_table_list` reports with no columns, which is a view whose table was dropped and which would fail the whole query. `hidden` there is 1 for a virtual table's hidden column, 2 for a virtual generated column, and 3 for a stored one. Functions come from `pragma_function_list`, which gives a name, a kind, and an argument count, so the arguments have no names or types and a negative count is one variadic argument. The search path is `temp`, then `main`, then the attached databases in attachment order.
- duckdb reads relations from `duckdb_columns`, `duckdb_tables`, and `duckdb_views`. `duckdb_columns` does not say which columns are generated, so each is looked for in the table's own `create` statement. Functions come from `duckdb_functions`, leaving out pragma functions, with a table function or table macro as `returnsSet`. Types come from `duckdb_types`, and since duckdb gives an enum's labels one type at a time, a second query unions one `enum_range` select per enum. The search path is the `search_path` setting, or else the current database's `main`, followed by `system.main` and `system.pg_catalog`.

## Output files

The log for a sql buffer is `stdpath("cache") .. "/db-query/" .. <pid> .. "/" .. <basename> .. ".md"`. Staging files are `staging-<n>.<extension>` in the same directory, numbered per call so two runs never share one. Both live there whatever the output directory is, so a buffer keeps one log for the session and `output.sweep()` clears it later.

Results files go to `output.directory()`, which returns the first of these that applies:

1. The path given to `:DBOutputDir`, for the rest of the session.
2. `output_dir` from `setup`.
3. The same `stdpath("cache") .. "/db-query/" .. <pid>` directory the log is in.

A results file is named `<basename>-<n>.<extension>`, where `n` is one past the highest number already in the directory. So running the same query twice does not write over a result still on screen, and a directory that is cleared out starts again at 1.

A `-o` path goes through `output.destination`: a relative path is resolved from the working directory, and a trailing slash or an existing directory takes the buffer's basename as the file name. The extension is replaced when the path already ends in `csv`, `tsv`, `txt`, or `log`, and appended otherwise. An existing file is confirmed before the query starts. A path inside the cache root is refused, because the sweep would delete it.

`output.owns(path)` returns whether the plugin should delete that file. It returns true when the file is under `output.directory()` and that directory is one the plugin clears up. The default directory under the cache is always cleared. A custom `output_dir` set in config is cleared unless `output_cleanup` is off, and a `:DBOutputDir` path is never cleared. `Source:close` runs on the sql buffer's `BufWipeout` and deletes the log and every file in `self.files` that `output.owns`.

`output.sweep()` runs at `setup` and deletes cache subdirectories whose pid is no longer running, and the partly written catalog files under `catalog/` whose pid suffix is not running. That is what covers an nvim that was killed, since a file is otherwise deleted with the sql buffer that produced it.

Saved catalogs live in `stdpath("cache") .. "/db-query/catalog/"`, outside any pid directory, so they survive the sweep and the next session finds them. "The saved file" under "Catalog" describes them.

## Reading sql

`sql/lex.lua` is the only module that scans sql text. `tokens(dialect, text)` splits it by the dialect's lex rules: which quotes open a string and whether a backslash escapes inside it, `E''` strings, which characters quote an identifier, the line comment forms, nested block comments, dollar quotes, parameter forms such as `$1` or `@total`, and `::`. A dialect with `commands` also reads a client command as one `meta` token, which is a psql backslash line or a mysql `delimiter` line to the end of its line, or mysql's two-byte `\g` and `\G`, and reads the client's variables, such as psql's `:name`. Every dialect produces the same token kinds, and every other module works on those tokens, so a `;` or a keyword inside a string, a comment, or a function body is never read as code. The lexer marks each word the dialect reserves as `token.reserved`, so a reserved word is never taken for an alias.

The lexer also tracks the delimiter a client command sets. After a mysql `delimiter //` line, `//` is the `;` token, a literal `;` is a `separator` token that stays inside its statement, and a word, number, parameter, or operator ends where the delimiter starts, so `end$$` is `end` followed by the terminator. A `delimiter ;` line puts it back.

`sql/statements.lua` says where one statement ends. `terminators` marks a `;` outside one of the dialect's blocks, such as a postgres `begin atomic` body, and a client command that sends the query. In psql that is `\g` and its variants, `\watch`, `\crosstabview`, and a backslash line ending in `;`. In mysql every command ends a statement, `delimiter` included, because the client runs the statement it has read so far before it changes the delimiter. `split` divides the tokens at them. `statementAt` and `rowKind` in `sql/init.lua` are built on those two, which is why `:DBQueryStatement` on a `create function` selects the whole function, body included.

The rest of `sql/` says what the cursor is in. `context.at(document, cursor)` takes a `dbquery.Document`, which is a dialect, the text, and its tokens, so text lexed once can serve every request against it. It returns a `dbquery.CursorContext`: the word under the cursor, the kind of name that belongs there, the clause, the function call and argument number, the insert target and position, the column or type a string at the cursor belongs to, and the relations in scope as `dbquery.ScopeRelation`s, innermost query block first. Inside a string the word is the text between the quotes on the cursor's line, so a string left open never swallows the lines below it. It is built in layers:

- `syntax.lua` nests the statement's tokens by parentheses and brackets, stores the dialect on every group, and labels each item with its clause and its query block by the dialect's clause rules. A new block starts at `union`, `intersect`, or `except`, and at a query word that heads a statement of its own, so two statements with no `;` between them keep their relations apart.
- `role.lua` says what a parenthesized group is to its parent: a subquery, a call, an insert's column list or values row, the column list of a named table, or a filter, over, or within group clause.
- `scope.lua` reads the relations of from, join, using, and write-target clauses with their aliases and alias column lists, the CTEs a `with` defines, and the table an insert writes to. A subquery or CTE holds the relations its select reads in `sources`, so a `*` in its columns can be expanded.
- `columns.lua` names the output columns of a select the way postgres does: an alias, the column of `t.col` or `x::type`, or the function of a call.
- `body.lua` finds the `do` block or function body holding the cursor, and the parameters, declared variables, loop variables, and `new` and `old` in scope there. The body is then read as sql of its own.
- `context.lua` walks outward from the group holding the cursor, collecting what each of those reports. It collects the relations of each query block until the walk crosses a link the inner query cannot see through, which is a CTE body or a from item written without `lateral`, and past that point collects only CTEs. A query in a select list or a where clause is correlated, so it sees the relations of the query around it.

The scanner reads clause structure and nothing more. A cast, an operator, or an expression is a run of opaque tokens.

The text is usually half typed. A group still open at the cursor, such as `coalesce(t.`, is closed where the next keyword that starts a clause appears after the cursor, so the `from` that follows still puts its tables in scope. A `(` written after a name holds a call's arguments or a column list, never a query, so it is also closed where a statement starts after the cursor. A group whose first word starts a query stays open, because clause keywords belong inside it.

**Why a hand-written scanner.** tree-sitter-sql rejects `lateral`, `delete ... using`, `::type[]`, and `tablesample` even in complete statements, and half-typed text parses into ERROR nodes that lose the tables around the cursor. tree-sitter-postgres parses postgres, but using it from nvim needs a C compiler or a wasmtime build, and it replaces only the parse: which relations the cursor can see, what a CTE's columns are, and where `excluded` is in scope are hand-written rules either way.

## Dialects

A `dbquery.Dialect`, defined in `lua/db-query/sql/dialect/init.lua`, is data and holds no code of its own beyond a rule's `test`:

- `lex`, the rules `sql/lex.lua` tokenizes by, listed under "Reading sql".
- `commands`, present only for a dialect read the way one client reads it: `at`, which finds a client command starting at a byte, the pattern of a client variable, `sends`, which says whether a command sends the query typed before it, and `delimiter`, which returns the statement delimiter a command sets.
- `reserved`, the words that are never an alias.
- `keywords`, the words completion offers, one set per place the cursor can stand. Each `dbquery.Clause` name holds what may be written after that clause, and `expression`, `operator`, `quantifier`, `projection`, `case`, `call`, and `closes` hold the words around a value. "Language server" below describes how they are picked. `standard` defines every set, `postgres` adds `returning`, `merge`, and `ilike` among others, `mysql` removes `fetch` and `lateral` and adds `regexp` and `straight_join`, `sqlite` adds `glob`, `regexp`, and `match`, and `duckdb` adds `qualify`, `exclude`, and `replace`.
- `queries`, the words that start a statement which returns or writes rows.
- `definitions`, the words that start a statement which changes the catalog: `create`, `alter`, `drop`, and `comment` in `standard`, plus `import` in `postgres` and `rename` in `mysql`.
- `clauses`, rules of the form `{ word, after, within, test, clause }`. The first rule that applies to a word labels it with its clause.
- `joins`, the words that start a join, and `beforeRelation`, the other words a table name may follow, such as `from` or `into`.
- `callable`, the reserved words that name a function when `(` follows. Such a call never starts a clause or a query, which is what keeps mysql's `replace(col, 'x', 'y')` in a select list from being read as a `replace` statement.
- `fromSuffixes`, patterns of what may follow a table in `from`, such as `tablesample system (10)` or a mysql index hint.
- `blocks`, the word sequences, such as `begin atomic`, that open a body whose `;` stays inside the statement.
- `folds`, how the server reads an unquoted name: `lower` in `standard` and the postgres family, where `Trades` is the table `trades`, and `none` in `mysql`, `sqlite`, and `duckdb`, where it matches any case.
- `signatures`, the functions the grammar defines rather than the catalog, keyed by lowercase name, each with a `label`, the `parameters` a comma separates, and whether the last one repeats. `standard` has `coalesce`, `nullif`, `cast`, `extract`, `substring`, `trim`, `position`, and `overlay`. `postgres` and `mysql` add `greatest` and `least`. `sqlite` keeps only `coalesce`, `nullif`, and `cast`.

`derive(base, changes)` builds one dialect from another. Each set in `changes` is added to the base's, each lex rule in `changes` replaces the base's, and the derived dialect's clause rules are tried before its base's, so a rule that narrows one of the base's wins. `signatures` and `keywords` replace the base's table whole, since a dialect may lack a form or a word its base has, and `dialect.without(base, "a b")` builds a set from another with those words removed.

- `standard` is the base: `'` strings with doubled quotes, `"` identifiers, `--` and `/* */` comments, and the clauses of select, insert, update, and delete.
- `postgres` is the sql the server reads: `E''` strings, nested comments, dollar quotes, `$1` parameters, `::`, `returning`, `merge`, `on conflict`, `tablesample`, and `begin atomic` blocks.
- `psql` is `postgres` plus what psql handles before the server sees the text: backslash lines as commands, `:name` variables, and which commands send the query. The postgres client uses it.
- `sqlite` is `postgres` with sqlite's parameters in place of `$1`: `?`, `?1`, `:name`, `@name`, and `$name`.
- `duckdb` is `postgres` with duckdb's parameters: `$1`, `?`, and `$name` when no `$` follows it, since `$tag$` opens a dollar quote.
- `mysql` has backslash escapes in `'` and `"` strings, backtick identifiers, `#` comments and `--` comments only when whitespace or the end of the text follows the dashes, `@var` and `?` parameters, and `straight_join`. Its commands are `\g`, `\G`, and a `delimiter` line, which the client reads only at the start of a line and in any letter case. `insert` and `replace` open the insert target at the start of the statement, so the modifiers and the optional `into` in `insert ignore into t set a = 1` read as an insert, `on duplicate key update` is a `set` clause, and an index hint or `partition (...)` after a table is skipped like `tablesample`.
- `mariadb` is `mysql` plus `returning`.

Each file under `client/` names its dialect, and `client.dialect(connection)` returns it. Reading with the wrong one splits statements in the wrong place. `'it\'s; fine'` read by postgres rules ends the string at `\'`, and the `;` after it split the statement for `:DBQueryStatement` and sent a mysql select to the log.

A mysql `delimiter` line changes what ends a statement, and the client acts on it only when it reads the line itself. So the lexer tracks the delimiter, as "Reading sql" describes, and `statementAt` selects a whole `create procedure` body up to its `//`. The statement then has to reach the client with the delimiter it was written under. `sql.delimiterCommand(dialect, lines)` returns the last `delimiter` line in `lines` when it leaves a delimiter other than `;`, and `selection.text` puts that line ahead of sql taken from below it. The mysql and mariadb clients send the statement on stdin, where the client reads it as a script and acts on the line. `sql.rowKind` skips a command that only sets the delimiter, so the query still writes a results file, and `sql.stripTerminator` removes a delimiter of any length as it removes a `;`.

## Language server

`lsp/init.lua` is a server nvim's lsp client calls in process. `attach(buf)` calls `vim.lsp.start({ name = "db-query", cmd = server }, { bufnr = buf })`, where `server` is a function returning the `request`, `notify`, `is_closing`, and `terminate` that `vim.lsp.rpc` would otherwise wrap around a child process. `setup` calls `attach` from a `FileType` autocmd for `sql`, `mysql`, and `plsql`, and once for each such buffer already loaded, while `lsp` is on. It does not go through `vim.lsp.enable`, which skips a buffer with a `buftype`, and the scratch buffers other plugins open for sql are `nofile`.

The server declares `positionEncoding = "utf-8"`, completion triggered by `.`, `(`, `'`, and `"`, signature help triggered by `(` and `,`, and hover. It reads `snippetSupport` out of the `initialize` params, and snippet items are sent only when it is true. A completion request whose trigger character is a quote that closed a string, or a quoted name, is answered with no items, so the menu does not open on a closing quote. A request made by hand there is answered as any other.

**How a request is answered.** nvim calls `request` in the requester's own call stack, which during completion is under textlock, and records the request as pending only after `request` returns. So `request` reads the buffer at once, through `document.capture`, which only reads and so is allowed under textlock, and hands the answer to `respond`, which computes it through `vim.schedule` and `main.run` on a later pass of the main loop. `respond` answers each id once and calls the `replied` callback before the response callback, so nvim has dropped the request from its pending table before the handler runs. A `$/cancelRequest` marks the id cancelled, and a cancelled request is only marked answered, its callback never called, which is what nvim's own rpc client does. An error a handler throws becomes an `InternalError` response, a method with no handler gets `MethodNotFound`, and `exit` and `terminate` call `dispatchers.on_exit` once so nvim drops the client.

`document.capture(uri)` returns the current buffer's lines, `b:db`, and filetype when `uri` is that buffer's uri, and nil otherwise. Every unnamed buffer's uri is `file://`, so the check cannot tell one from another, and the request is taken to be about the current buffer, which is the buffer every completion, hover, and signature request is made from. `document.open` runs on the main loop: it resolves `b:db` through `dadbod.resolve`, takes the client's dialect, lexes the text once, and takes the catalog from `catalog.get`, which returns what is known and never waits. A buffer with no connection or an unknown client reads by `standard`, or by `mysql` for a `mysql` filetype, and has no catalog, so it gets keywords and the names in scope only. `offset` and `position` convert between LSP positions and byte offsets in the joined text, counting bytes both ways since the encoding is utf-8.

**Names.** `names.lua` matches a name as sql writes it against the catalog. `parts` splits a dotted name, keeping a quoted part whole with its doubled quotes undoubled. A quoted part matches exactly. An unquoted part matches by the dialect's `folds`: lowercased against the catalog's name where `folds` is `lower`, and in any case where it is `none`. The folded match is tried first and the any-case match second, so on postgres `trades` finds the table `trades` ahead of a table `Trades`, and finds `Trades` when there is no other. A single-part name is looked for in `searchPath` order, then anywhere when exactly one schema holds that name. A two-part duckdb name `db.table` also matches the `main` schema of the database `db`. `columns` returns what a `dbquery.ScopeRelation` offers: a table's columns from the catalog, and a subquery's or CTE's from the names its select gives, with `*` expanded from its `sources` and a `seen` set stopping a recursive CTE from expanding itself. `insertable` leaves out generated and identity columns and hidden ones. `quote` writes a table, column, or schema name bare when the dialect reads the bare word back as that name, and quoted when the name is not a plain identifier, when folding would change it, or when the dialect reserves the word, as in `"order"`. `callable` writes a function name and never quotes it for being reserved, because `coalesce(` is grammar and `"coalesce"(` is not.

**Completion.** `complete.items` picks by `context.kind`:

- `relation`: the CTEs in scope, the tables and set-returning functions in the search path, and every schema. After `insert into`, each table also gets its insert snippet.
- `column`: each relation in scope gives its columns and then its alias, a function body gives its variables, the catalog gives the functions in the search path with procedures left out, and the dialect gives the keywords that may be written where a value goes.
- `qualified`: the columns of the relation in scope the qualifier names. When none does, the columns of the catalog table it names, plus the tables and functions in the schema it names.
- `columns_of`, and an insert's column list: the columns of that one table.
- `literal`: the labels of the enum the string belongs to, which `literal.lua` finds in the catalog. `context.castTo` names the type when the string is written as `'x'::mood` or `cast('x' as mood)`, and wins over the rest. Otherwise `context.valueOf` names the column the string is compared to or assigned to, read back over the comparison words before the string, or before the list holding it, and looked up among the relations in scope. Otherwise the string is in an insert's values row, and the column list names its column by position. Each item writes the label with any quote in it doubled, plus the closing quote when the string has none.
- `keyword`: the dialect's `keywords` for the clause holding the cursor, or for `start` before the first clause.

A keyword list is one entry of the dialect's `keywords` table, described under "Dialects". Where a value goes, `valueKeywords` reads the token before the word under the cursor. When nothing, an operator, a cast, a comma, or a reserved word outside `closes` stands there, a value is being opened, so the `expression` words are offered, with `quantifier` after an operator and `projection` just after `select` or as a call's first argument. Otherwise a value has just been written, so the `operator` words and the clause's own list are offered, with `call` just after a call. An open `case` adds the `case` words either way.

Every item's `textEdit` replaces the whole word under the cursor, from its first byte to the later of the cursor and its last byte. `filterText` is the unquoted name, unless the typed word opens with a quote, in which case it is the name as written, so `"P` filters against `"Px"`. `sortText` is the group number followed by the item's position, so an engine that sorts by it shows insert helpers (0), columns in table order (1), aliases and CTEs (2), variables (3), relations (4), schemas (5), keywords (6), and functions (7). When `searchPath` is empty, which a mariadb server without a default database has, an unqualified name finds nothing, so every table is offered as `db.table`.

`insert.lua` writes the column list every time, so a column the user drops is one deletion away. After `insert into`, each table gets a second, snippet item that writes `t (cols) values (${1:col /* type */}, ...)$0`. Inside the column list, `all columns` is offered while the list is empty and more than one column remains, plus each insertable column not listed yet. Inside an empty `values (` row after a written column list, one snippet writes a placeholder per listed column. With no column list written there is no values item, since the values would land in whichever columns come first. Snippet text escapes `\`, `$`, and `}`, and breaks up a `/*` or `*/` inside a type such as `enum('a', 'b')` so it cannot close the comment early.

**Signature help.** `signature.help` reads `context.call`. The dialect's `signatures` form for the name comes first, then every catalog overload `names.functions` finds. An overload's label leaves out `table` arguments, and `out` arguments unless the function is a procedure, since a call never passes them. `activeParameter` is the argument number minus one, clamped to the last parameter when that parameter is variadic, and one past the end otherwise, which the protocol reads as no parameter. A grammar form whose arguments keywords separate has no `parameters` and no `activeParameter`.

**Hover.** `hover.hover` returns markdown: a column as `table.name type not null default ...` with its enum labels and comment, a table with its kind and every column, or each overload of a function. A qualified word is looked up through the relation in scope its qualifier refers to, then as a column of a table the qualifier names, then as a schema-qualified catalog name. An unqualified word is a table in scope first, then a column of any relation in scope, then a catalog name. A word followed by `(` is looked up as a function only.

## Adding a database

Add a file under `lua/db-query/client/` that returns a `dbquery.Client`, and map its url scheme to it in `CLIENTS` in `lua/db-query/client/init.lua`:

```lua
---@type dbquery.Client
return {
  name = "example",
  catalog = function(request, done)
    -- calls done with a dbquery.Catalog
  end,
  rows = { query = true, returning = true },
  delimited = "csv",
  dialect = require("db-query.sql.dialect.standard"),

  command = function(spec)
    -- returns a dbquery.Command
  end,
}
```

`name` is what `catalog.clients` names the client by. `catalog` reads the database's catalog, as "Catalog" describes: it gets a `dbquery.CatalogRequest`, runs its queries through `request.query`, and calls `done` once with a `dbquery.Catalog` or with why there is none. `catalog/rows.lua` has the helpers the built-in functions share.

`rows` names the row kinds the client writes to a file, keyed by `dbquery.RowKind`. A kind missing here goes to the log. `delimited` is the extension for csv format, `csv` or `tsv`, whichever the client actually writes. Set `embedded = true` when the database is a file the client opens itself, which skips the `select 1` test a connection gets before a buffer takes it.

`dialect` is the `dbquery.Dialect` the client reads sql by, which decides where `:DBQueryStatement` cuts a statement and which statements have rows. Use the closest one under `lua/db-query/sql/dialect/`, or add a file there that derives a new one from it with `dialect.derive(base, changes)`. psql runs backslash lines itself and the postgres server never sees them, so `psql.lua` derives from `postgres.lua` and adds those lines as `commands`. Give a client that runs lines of its own the same two files.

Two schemes can share one client. `postgres` and `postgresql` both map to `client/postgres.lua`, and `client/mysql.lua` returns `{ mysql, mariadb }`, both built by its `client(binary)` around a different executable. The mariadb scheme exists because MariaDB ships `mariadb` and symlinks `mysql` to it, while MySQL 8 removed options MariaDB still takes, `--ssl-verify-server-cert` among them, so on a machine holding both the scheme is what reaches the right binary.

`command` receives a `dbquery.CommandSpec`:

- `connection`, the resolved url.
- `statement`, the sql.
- `format`, `"text"`, `"csv"`, or `"value"`.
- `kind`, the row kind, or nil when the run has no results file.
- `path`, the results file, set whenever `kind` is.
- `staging`, a whitespace-free path in the cache directory the client may write to in place of `path`.
- `readonly`, true when the statement must not write, which only the catalog's queries ask for.

It returns a `dbquery.Command`:

- `argv`, required.
- `env` and `stdin`, optional.
- `stdout`, a file the shell must catch stdout in. Set this to `spec.path` when the client has no way to write rows to a file itself.
- `staged`, true when the client wrote to `spec.staging` and `run.lua` must move it onto `spec.path`.
- `sessionFile`, the path where the client records its server-side session id, for `cancel`.

When `spec.path` is nil, the command must make the client print its own transcript to stdout, since everything it prints goes to the log. When `spec.path` is set, the command must put the rows in that file and nothing else, either by telling the client to write there, by writing to `spec.staging` and returning `staged = true`, or by returning `stdout = spec.path`.

When `format` is `"value"`, `spec.path` is nil and the command must make the client print the statement's result alone to stdout, unaligned, with no header, echo, or timing, because `client.value` hands that stdout back to lua. `client.value` takes a `dbquery.ValueSpec`, which is the connection, the statement, a timeout, and `readonly`. psql runs with `-A -t -q`, and its script still records the backend pid in `sessionFile` so the test can be cancelled server-side. mysql and mariadb run with `--batch --skip-column-names --raw`, sqlite3 with `-batch -noheader -list`, and duckdb with `-noheader -list`. A catalog query selects one json object per row, so in this format each line of stdout is one object for `catalog/rows.lua` to decode.

When `readonly` is set, the command keeps the statement from writing. sqlite3 takes `-readonly`. duckdb takes `-readonly` for a file, and never for an in-memory database, which refuses the flag and has no file to protect. psql wraps the statement in `BEGIN READ ONLY` and `ROLLBACK`. mysql and mariadb wrap it in `start transaction read only` and `rollback`, which refuses a row change, but a `create`, `alter`, or `drop` commits that transaction and runs.

Add `cancel` only if the database has a server that can be asked to stop a query. It takes the connection and a session id and returns the argv that cancels. To get that session id, `command` must also return `sessionFile`, a path the client writes its own server-side id to. `client.cancel` reads the number out of that file. Without both, `Process:cancel` falls back to sending `SIGINT` to the client, which is the right thing for an embedded database like duckdb or sqlite3 that has no server to ask.
