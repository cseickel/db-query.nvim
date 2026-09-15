# Architecture

A query is sent to a cli client, which writes what it prints to a log file and any rows to a results file, and those files are opened in a window. This keeps large result sets out of lua memory and off the nvim thread. When paired with exporting to csv and opening it with csv-table, the size of the result set that we can effectively handle is measured in GBs.

## Modules

All modules are in `lua/db-query/`.

Config:

- `config.lua` holds what `setup` was given, merged with the defaults.

Entry points:

- `init.lua` is the public API: `setup`, `execute`, `connect`, `output`, `outputDir`, and `status`. Keymaps can call it directly.
- `command.lua` registers `:DBQuery`, `:DBQueryStatement`, `:DBConnect`, `:DBOutput`, and `:DBOutputDir`, and parses their `-f` and `-o` arguments into what `init.lua` takes.
- `parquet.lua` turns a `*.parquet` being opened into a duckdb query against it.

Objects that make up a running query:

- `run.lua` is the query in flight: the process, the log and results file it is writing, and how it ended.
- `pane.lua` is the window showing one of those files.
- `indicator.lua` is the bar, spinner, clock, and cancel key drawn in the sql buffer.
- `source.lua` is the buffer queries are run from. It connects the run, indicator, and pane, remembers the files its runs have written, and deletes them when the buffer is wiped.

Everything else is helper functions:

- `selection.lua` captures the lines a query comes from, which may be a range, the visual selection, the whole buffer, or the buffer and cursor row for the statement at the cursor, and later turns them into the sql to run.
- `sql/init.lua`, required as `db-query.sql`, reads enough of a statement to say whether it returns rows, finds the statement around the cursor if that selection was requested, and finds the mysql `delimiter` command in effect above it.
- `sql/dialect/` holds one `dbquery.Dialect` per way of reading sql: `standard`, `postgres`, `psql`, `sqlite`, `duckdb`, `mysql`, and `mariadb`. Every module under `sql/` reads by the dialect it is given. "Dialects" below describes them.
- `sql/lex.lua` splits sql into tokens by a dialect's rules. Everything that reads sql reads its tokens.
- `sql/statements.lua` says where one statement ends and the next begins.
- `sql/syntax.lua`, `sql/role.lua`, `sql/scope.lua`, `sql/columns.lua`, `sql/body.lua`, and `sql/context.lua` say what the cursor is in, for completion, hover, and signature help. Nothing calls them yet. "Reading sql" below describes them.
- `connect.lua` decides which connection a sql buffer runs against, from its modeline, the picker, or the `g:db` the last pick set, and tests each new one before storing it.
- `modeline.lua` reads and rewrites the `-- @db-query connection=[name]` comment.
- `dadbod.lua` holds the calls into vim-dadbod and vim-dadbod-completion: resolving a written url, and pointing completion at a buffer's new `b:db`.
- `connections.lua` provides the list of connections that the database chooser offers.
- `url.lua` pulls the scheme, file path, password, and query parameters out of a dadbod url.
- `client/init.lua`, required as `db-query.client`, maps each url scheme to its client, and through it turns a connection and a statement into a command line, says which kinds of rows the client can write to a file, and names the dialect it reads sql by. Each client is a file beside it: `client/postgres.lua`, `client/sqlite.lua`, `client/duckdb.lua`, and `client/mysql.lua`, which builds both mysql and mariadb.
- `output.lua` names the log, the results file, and the staging file, and decides which files the plugin deletes.

## Example Execution

```
  :DBQuery ──┐
             ├──► init.execute ──► Source.of(buf):execute ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐
  a keymap ──┘         │                    │                                            ╎
                       ▼                    ├──► Run        cli client process           ╎
                   db#resolve               │               Run:onFinish() ◄╌╌subscribe╌╌┤
                                            ├──► Indicator  spinner / timing display ╌╌╌╌┤
                                            └──► Pane       window with log, then rows ╌╌┘
```

1. `command.lua` parses the arguments and calls `require("db-query").execute`. A keymap calls `execute` with the same options table.

2. `M.execute` in `init.lua` prepares the query:

    - `selection.capture(opts)` returns the lines the query comes from, and for `:DBQueryStatement` the whole buffer with the cursor row. The lines are read before any prompt opens, because a `vim.ui` prompt ends visual mode and the selection goes with it. When every line is blank, the query is refused here, before any prompt.
    - When `-o` was given without a path, `vim.ui.input` asks for one, prefilled with `b:db_last_output_path`.
    - When `connect.testing` names a connection test still pending for the buffer, the query is refused, so it never runs on the connection that test may replace.
    - `dadbod.resolve` expands `$VAR` in `b:db` through `db#resolve`. When the buffer has no connection, `connect.pick` asks for one and the rest continues in its callback.
    - `client.dialect(resolved)` returns the dialect the connection's client reads sql by, and `selection.text(capture, dialect)` returns the sql and its `span`, the first and last line it came from. The statement at the cursor is found here rather than at capture, because where a statement ends depends on the dialect: a `\'` inside a mysql string keeps the string open, and in postgres it closes the string. When the buffer lines above the sql leave a mysql `delimiter` other than `;` in effect, the command that set it is put ahead of the sql, so the client ends the statement where the buffer does. When the statement comes back empty, which happens when the cursor sits between statements, the query is refused with "no query to run".
    - `Source.of(buf):execute(ctx)` starts the work. The `dbquery.Context` holds the request as it stood when the user ran it, the dialect included, and every part of the run reads what it needs from `run.ctx` rather than being handed it.

3. `Source:execute` cancels whatever this buffer was running and stops its indicator, calls `Run.start`, records the results file in `self.files`, then attaches an `Indicator` and calls `Pane:display`. Both of those subscribe to the run.

4. `Run.start` decides where output goes and starts the client:

    - `output.log(srcName)` returns the buffer's log under the cache directory, creating it if needed.
    - `sql.rowKind(ctx.dialect, ctx.sql)` returns `"query"`, `"returning"`, or nil.
    - `client.target(resolved, kind, format)` returns the results file extension when the client writes that kind of rows to a file, and nil otherwise. With nil there is no results file, and a `-o` path draws a warning that nothing will be written to it.
    - `output.path(srcName, extension, chosen)` names the results file and creates it empty. `output.staging(extension)` names a file in the cache directory, with no whitespace in its path, for a client that cannot write to the results path itself.
    - `client.command(spec)` returns the argv, env, stdin, and where the client records its server session, plus either `stdout`, a file the shell must catch stdout in, or `staged`, meaning the client wrote to the staging file.
    - `announce` appends a header to the log, so the pane has something to show before the client prints anything.
    - `writingTo` wraps the argv in `sh -c`. Both streams append to the log, unless the command named a `stdout` file, in which case stdout goes there and only stderr reaches the log. `vim.system` runs it detached.

5. When the client exits, `finish` appends the `[1 finished in 1.234s]` footer to the log, moves a staged file onto the results path when the run succeeded, then schedules the status change and calls every subscriber. Each subscriber is called in a `pcall`, so that one throwing cannot stop the rest. If `Pane` threw while opening the window, `Indicator` would never be told to stop and the spinner would run forever.

6. `Indicator:stop` removes the bar and the cancel key. `Pane` opens the results file when the run succeeded and produced one, and otherwise reloads the log so its footer shows.

## Design Decisions

**A buffer runs one query at a time.** Starting a second query cancels the first. The reason is `indicator.lua`: the bar, the extmarks, and the cancel key are buffer-local, so a second query would draw over the first and take its key. `source.lua` is where this rule is kept.

**`run.lua` reads no buffers and opens no windows.** A Run holds a process and two file paths. `Run:onFinish` registers a callback, and a Run with no callbacks is fine. `parquet.lua` runs its `create view` through `client.run` with nothing drawn.

**Cancelling is a request.** `Run:cancel` queries the server through a second connection where there is one (`pg_cancel_backend`) and sends `SIGINT` where there is not, then leaves the run `running` until the client actually exits and reports the cancellation itself. So a query that has been replaced is still running and can still finish. `Pane` compares `self.run == run` before touching the window, and `Pane:stop` disconnects it from a run it no longer shows.

**Output never passes through lua.** Anything that reads a result file into a lua string reintroduces the memory cost this design exists to avoid.

**The client's output is not parsed.** What is in the log is what the client printed, between the header `announce` writes and the footer `finish` writes. The results file holds what the client wrote and nothing else.

**The client writes its own rows where it can.** psql, sqlite3, and duckdb are told the results path and write rows there themselves, which leaves stdout and stderr both free for the log, so command tags, timing, and errors arrive in the order the client printed them. mysql and mariadb have no such mechanism, so the shell catches their stdout in the results file and only stderr reaches the log.

**One log per sql buffer, appended.** Every run of a buffer writes to the same log, always under the cache directory, whatever the output directory is. A cancelled query keeps writing while its replacement is already appending to the same file, so each run has a number that appears in both its header and its footer.

**A failed run keeps its results file.** Two runs pointed at the same `-o` path share it, so deleting the file on failure would take the other run's output with it. The log holds the reason the run failed.

**Output files are ordinary buffers.** `Pane:show` lists the buffer and leaves `bufhidden` alone, so closing the window keeps the file and `:DBOutput` can bring it back. `Source:close` deletes the log and every results file `output.owns` when the sql buffer is wiped, which is what lets you move between the log and the rows as often as you like.

## The log and the results file

Every run appends to the log. A run also writes a results file when `sql.rowKind` finds rows and `client.target` says the client files that kind.

`sql.rowKind` looks at a single statement, read by the connection's dialect. It reads the tokens `sql.lex` produces, so a `;` or a keyword inside a string, a comment, or a dollar-quoted body counts for nothing. Text that holds a second statement returns nil. So does text that holds a client command, such as psql's `\gset` or `\x`, which cannot go inside COPY, or mysql's `\G`, whose vertical output is not rows. A mysql `delimiter` line changes nothing about the rows, so it is skipped over. Otherwise the first word decides:

- `select`, `with`, `table`, and `values` are `"query"`. A `with` holding the word `insert`, `update`, `delete`, or `merge` anywhere returns nil, because Postgres refuses a data-modifying CTE inside COPY.
- `insert`, `update`, `delete`, and `merge` that mention `returning` are `"returning"`.
- Any other statement, such as `create table` or an `update` without RETURNING, returns nil. The client prints its command tag and row count to the log.

`client.target` returns the extension: the client's `delimited` (`csv`, or `tsv` for mysql and mariadb) for csv format, and `txt` for text format. The `log` extension never appears in the output directory.

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

`connect.lua` decides what goes in `b:db`. A buffer takes its connection from its modeline when it has one, and otherwise from `g:db`, which only the picker sets. A connection from the modeline or the picker is tested before it is stored, by running `select 1` through `client.command` on `vim.system` with a 10 second timeout, so nvim stays responsive while an unreachable host is tried. One that answers goes in `b:db` and `b:db_name`, and `dadbod.refetch` calls `vim_dadbod_completion#fetch`. That plugin records a buffer's database at `FileType`, when a modeline buffer's `b:db` is still empty and it falls back to `g:db`, and keeps it. Its `fetch` reads `w:db`, `t:db`, `b:db`, and `g:db` from the current window and buffer rather than the buffer it is given, so `refetch` runs it inside `nvim_buf_call`. One that fails clears `b:db` and sets `b:db_name` to `<name> CONNECTION ERROR`. `g:db` is copied into new buffers untested, because only a connection that answered is ever put there. A client marked `embedded` in its file under `client/`, sqlite3 or duckdb, passes without a test, because opening the file would create it when it is missing and fail when another duckdb process holds its lock.

Each buffer keeps only its latest test, so a slow one that finishes after the user chose something else is dropped. Until the latest one finishes, `b:db` still holds the connection it may replace, so `execute` refuses a query in that time. Queuing the query instead would let several pile up behind one test, and when that test failed each of them would open its own picker.

`dadbod.resolve` returns nil for an empty `b:db` rather than handing it to `db#resolve`, which would resolve it to `w:db`, `t:db`, `g:db`, or `$DATABASE_URL`. A buffer whose modeline connection failed has an empty `b:db`, and a query from it has to open the picker rather than run against a database the modeline never named.

The modeline is read on `FileType` and `BufWritePost`. The `FileType` handler reads it before it would copy `g:db`, so a buffer with a modeline never holds `g:db`'s url. `:DBConnect` in a buffer whose modeline names another connection rewrites the modeline after a confirm, and leaves `g:db` alone.

`connections.list` offers the `connections` setting when there is one, and otherwise vim-dadbod-ui's `connections.json` followed by `g:dbs`. Names already used are skipped, so neither source hides the other's entries.

## Output files

The log for a sql buffer is `stdpath("cache") .. "/db-query/" .. <pid> .. "/" .. <basename> .. ".log"`. Staging files are `staging-<n>.<extension>` in the same directory, numbered per call so two runs never share one. Both live there whatever the output directory is, so a buffer keeps one log for the session and `output.sweep()` clears it later.

Results files go to `output.directory()`, which returns the first of these that applies:

1. The path given to `:DBOutputDir`, for the rest of the session.
2. `output_dir` from `setup`.
3. The same `stdpath("cache") .. "/db-query/" .. <pid>` directory the log is in.

A results file is named `<basename>-<n>.<extension>`, where `n` is one past the highest number already in the directory. So running the same query twice does not write over a result still on screen, and a directory that is cleared out starts again at 1.

A `-o` path goes through `output.destination`: a relative path is resolved from the working directory, and a trailing slash or an existing directory takes the buffer's basename as the file name. The extension is replaced when the path already ends in `csv`, `tsv`, `txt`, or `log`, and appended otherwise. An existing file is confirmed before the query starts. A path inside the cache root is refused, because the sweep would delete it.

`output.owns(path)` returns whether the plugin should delete that file. It returns true when the file is under `output.directory()` and that directory is one the plugin clears up. The default directory under the cache is always cleared. A custom `output_dir` set in config is cleared unless `output_cleanup` is off, and a `:DBOutputDir` path is never cleared. `Source:close` runs on the sql buffer's `BufWipeout` and deletes the log and every file in `self.files` that `output.owns`.

`output.sweep()` runs at `setup` and deletes cache subdirectories whose pid is no longer running. That is what covers an nvim that was killed, since a file is otherwise deleted with the sql buffer that produced it.

## Reading sql

`sql/lex.lua` is the only module that scans sql text. `tokens(dialect, text)` splits it by the dialect's lex rules: which quotes open a string and whether a backslash escapes inside it, `E''` strings, which characters quote an identifier, the line comment forms, nested block comments, dollar quotes, parameter forms such as `$1` or `@total`, and `::`. A dialect with `commands` also reads a client command as one `meta` token, which is a psql backslash line or a mysql `delimiter` line to the end of its line, or mysql's two-byte `\g` and `\G`, and reads the client's variables, such as psql's `:name`. Every dialect produces the same token kinds, and every other module works on those tokens, so a `;` or a keyword inside a string, a comment, or a function body is never read as code. The lexer marks each word the dialect reserves as `token.reserved`, so a reserved word is never taken for an alias.

The lexer also tracks the delimiter a client command sets. After a mysql `delimiter //` line, `//` is the `;` token, a literal `;` is a `separator` token that stays inside its statement, and a word, number, parameter, or operator ends where the delimiter starts, so `end$$` is `end` followed by the terminator. A `delimiter ;` line puts it back.

`sql/statements.lua` says where one statement ends. `terminators` marks a `;` outside one of the dialect's blocks, such as a postgres `begin atomic` body, and a client command that sends the query. In psql that is `\g` and its variants, `\watch`, `\crosstabview`, and a backslash line ending in `;`. In mysql every command ends a statement, `delimiter` included, because the client runs the statement it has read so far before it changes the delimiter. `split` divides the tokens at them. `statementAt` and `rowKind` in `sql/init.lua` are built on those two, which is why `:DBQueryStatement` on a `create function` selects the whole function, body included.

The rest of `sql/` says what the cursor is in. `context.at(document, cursor)` takes a `dbquery.Document`, which is a dialect, the text, and its tokens, so text lexed once can serve every request against it. It returns a `dbquery.CursorContext`: the word under the cursor, the kind of name that belongs there, the clause, the function call and argument number, the insert target and position, and the relations in scope, innermost query block first. Nothing calls it yet. It is built in layers:

- `syntax.lua` nests the statement's tokens by parentheses and brackets, stores the dialect on every group, and labels each item with its clause and its union block by the dialect's clause rules.
- `role.lua` says what a parenthesized group is to its parent: a subquery, a call, an insert's column list or values row, the column list of a named table, or a filter, over, or within group clause.
- `scope.lua` reads the relations of from, join, using, and write-target clauses with their aliases and alias column lists, the CTEs a `with` defines, and the table an insert writes to. A subquery or CTE holds the relations its select reads in `sources`, so a `*` in its columns can be expanded.
- `columns.lua` names the output columns of a select the way postgres does: an alias, the column of `t.col` or `x::type`, or the function of a call.
- `body.lua` finds the `do` block or function body holding the cursor, and the parameters, declared variables, loop variables, and `new` and `old` in scope there. The body is then read as sql of its own.
- `context.lua` walks outward from the group holding the cursor, collecting what each of those reports.

The scanner reads clause structure and nothing more. A cast, an operator, or an expression is a run of opaque tokens.

The text is usually half typed. A group still open at the cursor, such as `coalesce(t.`, is closed where the next keyword that starts a clause appears after the cursor, so the `from` that follows still puts its tables in scope. A group whose first word starts a query stays open, because clause keywords belong inside it.

**Why a hand-written scanner.** tree-sitter-sql rejects `lateral`, `delete ... using`, `::type[]`, and `tablesample` even in complete statements, and half-typed text parses into ERROR nodes that lose the tables around the cursor. tree-sitter-postgres parses postgres, but using it from nvim needs a C compiler or a wasmtime build, and it replaces only the parse: which relations the cursor can see, what a CTE's columns are, and where `excluded` is in scope are hand-written rules either way.

## Dialects

A `dbquery.Dialect`, defined in `lua/db-query/sql/dialect/init.lua`, is data and holds no code of its own beyond a rule's `test`:

- `lex`, the rules `sql/lex.lua` tokenizes by, listed under "Reading sql".
- `commands`, present only for a dialect read the way one client reads it: `at`, which finds a client command starting at a byte, the pattern of a client variable, `sends`, which says whether a command sends the query typed before it, and `delimiter`, which returns the statement delimiter a command sets.
- `reserved`, the words that are never an alias.
- `queries`, the words that start a statement which returns or writes rows.
- `clauses`, rules of the form `{ word, after, within, test, clause }`. The first rule that applies to a word labels it with its clause.
- `joins`, the words that start a join, and `beforeRelation`, the other words a table name may follow, such as `from` or `into`.
- `callable`, the reserved words that name a function when `(` follows. Such a call never starts a clause or a query, which is what keeps mysql's `replace(col, 'x', 'y')` in a select list from being read as a `replace` statement.
- `fromSuffixes`, patterns of what may follow a table in `from`, such as `tablesample system (10)` or a mysql index hint.
- `blocks`, the word sequences, such as `begin atomic`, that open a body whose `;` stays inside the statement.

`derive(base, changes)` builds one dialect from another. Each set in `changes` is added to the base's, each lex rule in `changes` replaces the base's, and the derived dialect's clause rules are tried before its base's, so a rule that narrows one of the base's wins.

- `standard` is the base: `'` strings with doubled quotes, `"` identifiers, `--` and `/* */` comments, and the clauses of select, insert, update, and delete.
- `postgres` is the sql the server reads: `E''` strings, nested comments, dollar quotes, `$1` parameters, `::`, `returning`, `merge`, `on conflict`, `tablesample`, and `begin atomic` blocks.
- `psql` is `postgres` plus what psql handles before the server sees the text: backslash lines as commands, `:name` variables, and which commands send the query. The postgres client uses it.
- `sqlite` is `postgres` with sqlite's parameters in place of `$1`: `?`, `?1`, `:name`, `@name`, and `$name`.
- `duckdb` is `postgres` with duckdb's parameters: `$1`, `?`, and `$name` when no `$` follows it, since `$tag$` opens a dollar quote.
- `mysql` has backslash escapes in `'` and `"` strings, backtick identifiers, `#` comments and `--` comments only when whitespace or the end of the text follows the dashes, `@var` and `?` parameters, and `straight_join`. Its commands are `\g`, `\G`, and a `delimiter` line, which the client reads only at the start of a line and in any letter case. `insert` and `replace` open the insert target at the start of the statement, so the modifiers and the optional `into` in `insert ignore into t set a = 1` read as an insert, `on duplicate key update` is a `set` clause, and an index hint or `partition (...)` after a table is skipped like `tablesample`.
- `mariadb` is `mysql` plus `returning`.

Each file under `client/` names its dialect, and `client.dialect(connection)` returns it. Reading with the wrong one splits statements in the wrong place. `'it\'s; fine'` read by postgres rules ends the string at `\'`, and the `;` after it split the statement for `:DBQueryStatement` and sent a mysql select to the log.

A mysql `delimiter` line changes what ends a statement, and the client acts on it only when it reads the line itself. So the lexer tracks the delimiter, as "Reading sql" describes, and `statementAt` selects a whole `create procedure` body up to its `//`. The statement then has to reach the client with the delimiter it was written under. `sql.delimiterCommand(dialect, lines)` returns the last `delimiter` line in `lines` when it leaves a delimiter other than `;`, and `selection.text` puts that line ahead of sql taken from below it. The mysql and mariadb clients send the statement on stdin, where the client reads it as a script and acts on the line. `sql.rowKind` skips a command that only sets the delimiter, so the query still writes a results file, and `sql.stripTerminator` removes a delimiter of any length as it removes a `;`.

## Adding a database

Add a file under `lua/db-query/client/` that returns a `dbquery.Client`, and map its url scheme to it in `CLIENTS` in `lua/db-query/client/init.lua`:

```lua
---@type dbquery.Client
return {
  rows = { query = true, returning = true },
  delimited = "csv",
  dialect = require("db-query.sql.dialect.standard"),

  command = function(spec)
    -- returns a dbquery.Command
  end,
}
```

`rows` names the row kinds the client writes to a file, keyed by `dbquery.RowKind`. A kind missing here goes to the log. `delimited` is the extension for csv format, `csv` or `tsv`, whichever the client actually writes. Set `embedded = true` when the database is a file the client opens itself, which skips the `select 1` test a connection gets before a buffer takes it.

`dialect` is the `dbquery.Dialect` the client reads sql by, which decides where `:DBQueryStatement` cuts a statement and which statements have rows. Use the closest one under `lua/db-query/sql/dialect/`, or add a file there that derives a new one from it with `dialect.derive(base, changes)`. psql runs backslash lines itself and the postgres server never sees them, so `psql.lua` derives from `postgres.lua` and adds those lines as `commands`. Give a client that runs lines of its own the same two files.

Two schemes can share one client. `postgres` and `postgresql` both map to `client/postgres.lua`, and `client/mysql.lua` returns `{ mysql, mariadb }`, both built by its `client(binary)` around a different executable. The mariadb scheme exists because MariaDB ships `mariadb` and symlinks `mysql` to it, while MySQL 8 removed options MariaDB still takes, `--ssl-verify-server-cert` among them, so on a machine holding both the scheme is what reaches the right binary.

`command` receives a `dbquery.CommandSpec`:

- `connection`, the resolved url.
- `statement`, the sql.
- `format`, `"text"` or `"csv"`.
- `kind`, the row kind, or nil when the run has no results file.
- `path`, the results file, set whenever `kind` is.
- `staging`, a whitespace-free path in the cache directory the client may write to in place of `path`.

It returns a `dbquery.Command`:

- `argv`, required.
- `env` and `stdin`, optional.
- `stdout`, a file the shell must catch stdout in. Set this to `spec.path` when the client has no way to write rows to a file itself.
- `staged`, true when the client wrote to `spec.staging` and `run.lua` must move it onto `spec.path`.
- `sessionFile`, the path where the client records its server-side session id, for `cancel`.

When `spec.path` is nil, the command must make the client print its own transcript to stdout, since everything it prints goes to the log. When `spec.path` is set, the command must put the rows in that file and nothing else, either by telling the client to write there, by writing to `spec.staging` and returning `staged = true`, or by returning `stdout = spec.path`.

Add `cancel` only if the database has a server that can be asked to stop a query. It takes the connection and a session id and returns the argv that cancels. To get that session id, `command` must also return `sessionFile`, a path the client writes its own server-side id to. `client.cancel` reads the number out of that file. Without both, `Run:cancel` falls back to sending `SIGINT` to the client, which is the right thing for an embedded database like duckdb or sqlite3 that has no server to ask.
