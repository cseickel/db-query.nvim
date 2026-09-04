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

- `selection.lua` extracts the query out of the buffer, which may be a range, the visual selection, or the whole buffer.
- `sql.lua` reads enough of a statement to say whether it returns rows, and finds the statement around the cursor if that selection was requested.
- `connections.lua` provides the list of connections that the database chooser offers.
- `url.lua` pulls the scheme, file path, and password out of a dadbod url.
- `client.lua` turns a connection and a statement into a command line, and says which kinds of rows each client can write to a file.
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

    - `selection.text(opts)` returns the sql and its `span`, the first and last line it came from. The sql is read before any prompt opens, because a `vim.ui` prompt ends visual mode and the selection goes with it.
    - When `-o` was given without a path, `vim.ui.input` asks for one, prefilled with `b:db_last_output_path`.
    - `db#resolve` expands `$VAR` in `vim.b.db`. When the buffer has no connection, `M.connect` asks for one and the rest continues in its callback.
    - `Source.of(buf):execute(ctx)` starts the work. The `dbquery.Context` holds the request as it stood when the user ran it, and every part of the run reads what it needs from `run.ctx` rather than being handed it.

3. `Source:execute` cancels whatever this buffer was running and stops its indicator, calls `Run.start`, records the results file in `self.files`, then attaches an `Indicator` and calls `Pane:display`. Both of those subscribe to the run.

4. `Run.start` decides where output goes and starts the client:

    - `output.log(srcName)` returns the buffer's log under the cache directory, creating it if needed.
    - `sql.rowKind(sql)` returns `"query"`, `"returning"`, or nil.
    - `client.target(resolved, kind, format)` returns the results file extension when the client writes that kind of rows to a file, and nil otherwise. With nil there is no results file, and a `-o` path draws a warning that nothing will be written to it.
    - `output.path(srcName, extension, chosen)` names the results file and creates it empty. `output.staging(extension)` names a whitespace-free file in the cache directory for a client that cannot write to the results path itself.
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

**The client writes its own rows where it can.** psql, sqlite3, and duckdb are told the results path and write rows there themselves, which leaves stdout and stderr both free for the log, so command tags, timing, and errors arrive in the order the client printed them. mysql has no such mechanism, so the shell catches its stdout in the results file and only stderr reaches the log.

**One log per sql buffer, appended.** Every run of a buffer writes to the same log, always under the cache directory, whatever the output directory is. A cancelled query keeps writing while its replacement is already appending to the same file, so each run has a number that appears in both its header and its footer.

**A failed run keeps its results file.** Two runs pointed at the same `-o` path share it, so deleting the file on failure would take the other run's output with it. The log holds the reason the run failed.

**Output files are ordinary buffers.** `Pane:show` lists the buffer and leaves `bufhidden` alone, so closing the window keeps the file and `:DBOutput` can bring it back. `Source:close` deletes the log and every results file `output.owns` when the sql buffer is wiped, which is what lets you move between the log and the rows as often as you like.

## The log and the results file

Every run appends to the log. A run also writes a results file when `sql.rowKind` finds rows and `client.target` says the client files that kind.

`sql.rowKind` looks at a single statement, so anything holding a semicolon after the trailing one returns nil. It strips leading comments and reads the first keyword:

- `select`, `with`, `table`, and `values` are `"query"`. A `with` that mentions `insert`, `update`, `delete`, or `merge` anywhere returns nil, because Postgres refuses a data-modifying CTE inside COPY.
- `insert`, `update`, `delete`, and `merge` that mention `returning` are `"returning"`.
- Any other statement, such as `create table` or an `update` without RETURNING, returns nil. The client prints its command tag and row count to the log.

`client.target` returns the extension: the client's `delimited` (`csv`, or `tsv` for mysql) for csv format, and `txt` for text format. The `log` extension never appears in the output directory.

How each client fills the results file:

- psql runs a script on stdin. `\o 'path'` sends query output to the file, the statement runs either wrapped in `COPY (...) TO STDOUT WITH (FORMAT csv, HEADER)` for csv or as written for text, and `\o` sends output back to stdout. The same script first sends `SELECT pg_backend_pid()` to `sessionFile` for cancelling.
- sqlite3 takes `.mode csv` or `.mode box`, `.headers on`, and `.output "path"` as `-cmd` arguments. The double quotes are what let `.output` take a path with a space in it.
- duckdb has two routes because neither does everything. `COPY (...) TO 'path' (FORMAT csv, HEADER)` reaches a path containing a space but its argument must be a select, so it is used for csv `"query"` rows. `.output` takes any statement but splits its argument on whitespace and reads quotes as part of the name, so every other case sends `.output` to the whitespace-free staging file and returns `staged = true`. `finish` moves that file onto the results path when the run succeeded and removes it otherwise.
- mysql has no client-side redirect. `command` returns `stdout = spec.path` and the shell catches stdout there, with `--batch` for csv, which prints tab-separated rows in place of the ascii table. mysql's `rows` holds only `"query"`, so a RETURNING statement goes to the log.

Without a results file, psql runs with `-e` and `\timing on` so the log labels each statement's row count and elapsed time, and the other clients take the statement on their command line.

`Pane:display` shows the log the moment the run starts, with the cursor on the last line, and rereads it every 500ms. A window already holding a results file keeps it instead, so a rerun does not take away what you were reading. When the run finishes it stops the timer and shows the results file when the status is `ok` and there is one, and the log otherwise. `Source:output(view)` is what `:DBOutput` calls, and it reopens the window if it was closed. `"toggle"` picks whichever of the two files is not showing.

## Connections

`b:db` is what this plugin shares with vim-dadbod and vim-dadbod-completion. Two forms of the url are in play:

- The written form, which may hold `$PGPASS` or be the name of a dadbod variable. `b:db` on the sql buffer holds it, and `Pane:show` copies it onto the output buffer, so completion reads the same url in both windows.
- The resolved form from `db#resolve`, which is what the client is given. `url.withoutPassword` takes any password out of it and `client.lua` puts that password in the environment instead, because a command line is readable by every process on the machine.

`M.connect` also sets `g:db`, which is what gives the next sql buffer a connection without asking again, and calls `vim_dadbod_completion#fetch`, because that plugin reads `b:db` once per buffer and keeps what it found.

`connections.list` offers the `connections` setting when there is one, and otherwise vim-dadbod-ui's `connections.json` followed by `g:dbs`. Names already used are skipped, so neither source hides the other's entries.

## Output files

The log for a sql buffer is `stdpath("cache") .. "/db-query/" .. <pid> .. "/" .. <basename> .. ".log"`. Staging files are `staging-<n>.<extension>` in the same directory, numbered per call so two runs never share one. Both live there whatever the output directory is, so a buffer keeps one log for the session and `output.sweep()` clears it later.

Results files go to `output.directory()`, which returns the first of these that applies:

1. The path given to `:DBOutputDir`, for the rest of the session.
2. `output_dir` from `setup`.
3. The same `stdpath("cache") .. "/db-query/" .. <pid>` directory the log is in.

A results file is named `<basename>-<n>.<extension>`, where `n` is one past the highest number already in the directory. So running the same query twice does not write over a result still on screen, and a directory that is cleared out starts again at 1.

A `-o` path goes through `output.destination`: a relative path is resolved from the working directory, and a trailing slash or an existing directory takes the buffer's basename as the file name. The extension is replaced when the path already ends in `csv`, `tsv`, `txt`, or `log`, and appended otherwise. An existing file is confirmed before the query starts. A path inside the cache root is refused, because the sweep would delete it.

`output.owns(path)` returns whether the plugin should delete that file. It returns true when the file is under `output.directory()` and that directory is one the plugin clears up. The default cache location is always cleared. A custom `output_dir` set in config is cleared unless `output_cleanup` is off, and a `:DBOutputDir` path is never cleared. `Source:close` runs on the sql buffer's `BufWipeout` and deletes the log and every file in `self.files` that `output.owns`.

`output.sweep()` runs at `setup` and deletes cache subdirectories whose pid is no longer running. That is what covers an nvim that was killed, since a file is otherwise deleted with the sql buffer that produced it.

## Adding a database

Add an entry to `CLIENTS` in `lua/db-query/client.lua`, keyed by the url scheme:

```lua
CLIENTS.oracle = {
  rows = { query = true, returning = true },
  delimited = "csv",

  command = function(spec)
    -- returns a dbquery.Command
  end,
}
```

`rows` names the row kinds the client writes to a file, keyed by `dbquery.RowKind`. A kind missing here goes to the log. `delimited` is the extension for csv format, `csv` or `tsv`, whichever the client actually writes.

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
