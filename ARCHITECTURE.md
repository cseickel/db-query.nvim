# Architecture

How this works is that a query is sent to a cli client, which writes its output to a file, and the file is opened in a window. This allows us to handle large result sets without impacting memory usage or tying up the thread in nvim. When paired with exporting to csv and opening it with csv-table, the size of the result set that we can effectively handle is measured in GBs.

## Modules

All modules are in `lua/db-query/`.

Config:

- `config.lua` holds what `setup` was given, merged with the defaults.

Entry points:

- `init.lua` is the public API: `setup`, `execute`, `connect`, `outputDir`, and `status`. Keymaps can call it directly.
- `command.lua` registers `:DBQuery`, `:DBQueryStatement`, `:DBConnect`, and `:DBOutputDir`, and parses their `-f` and `-o` arguments into what `init.lua` takes.
- `parquet.lua` turns a `*.parquet` being opened into a duckdb query against it.

Objects that make up a running query:

- `run.lua` is the query in flight: the process, the file it is writing, and how it ended.
- `pane.lua` is the window showing that file.
- `indicator.lua` is the bar, spinner, clock, and cancel key drawn in the sql buffer.
- `source.lua` is the buffer queries are run from. It coordinates the and connects the run, indicator, and pane.

Everything else is helper functions:

- `selection.lua` extracts the query out of the buffer, which may be a range, the visual selection, or the whole buffer.
- `sql.lua` parses enough sql to decides whether sql can be exported as rows, and finds the statement around the cursor if that selection was requested.
- `connections.lua` provides the list of connections that the database chooser offers.
- `url.lua` pulls the scheme, file path, and password out of a dadbod url.
- `client.lua` logic to produce a command and argv array from a connection and a statement.
- `output.lua` decides which directory output goes to, names the file, and sets the deletion policy.

## Example Execution

```
  :DBQuery ──┐
             ├──► init.execute ──► Source.of(buf):execute ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐
  a keymap ──┘         │                    │                                            ╎
                       ▼                    ├──► Run        cli client process           ╎
                   db#resolve               │               Run:onFinish() ◄╌╌subscribe╌╌┤
                                            ├──► Indicator  spinner / timing display ╌╌╌╌┤
                                            └──► Pane       window with output file ╌╌╌╌╌┘
```
1. `command.lua` parses the arguments and calls `require("db-query").execute`. A keymap calls `execute` with the same options table.

2. `M.execute` in `init.lua` prepares the query:
   - `selection.text(opts)` returns the sql and its `span`, the first and last line it came from. This is read before anything can prompt, because opening a `vim.ui` prompt ends visual mode and takes the selection with it.
   - `sql.mode(statement)` returns `export` when the format is csv and the sql is a single row-returning statement, and `script` otherwise.
   - `chooseOutput` prompts for a path when `-o` was given without one.
   - `db#resolve` expands `$VAR` in `vim.b.db`. When the buffer has no connection, `M.connect` asks for one and the rest continues in its callback.
   - `Source.of(buf):execute(spec)` starts the work.

3. `Source:execute` cancels whatever this buffer was running, calls `Run.start`, then attaches an `Indicator` and calls `Pane:display`. Both of those subscribe to the run.

4. `Run.start` starts the client:
   - `client.command(resolved, sql, mode)` returns the argv, env, stdin, file extension, and where the client will record its server session.
   - `output.path(srcName, extension, chosen)` picks the file and creates it empty.
   - `writingTo` wraps the argv in `sh -c`, redirecting stdout to that path, and `vim.system` runs it detached.

5. When the client exits, `finish` writes the `[finished in 1.234s]` footer, then schedules the status change and calls every subscriber. Each subscriber is called in a `pcall`, so that one throwing cannot stop the rest. If `Pane` threw while opening the window, `Indicator` would never be told to stop and the spinner would run forever.

6. `Indicator:stop` removes the bar and the cancel key. `Pane` opens or rereads the window.

## Design Decisions

**A buffer runs one query at a time.** Starting a second query cancels the first. The reason is `indicator.lua`: the bar, the extmarks, and the cancel key are buffer-local, so a second query would draw over the first and take its key. `source.lua` is where this rule is kept.

**`run.lua` knows nothing about buffers or windows.** It publishes `onFinish` and anything may subscribe, including nothing at all. `parquet.lua` runs its `create view` through `client.run` with nothing drawn.

**Cancelling is a request.** `Run:cancel` queries the server through a second connection where there is one (`pg_cancel_backend`) and sends `SIGINT` where there is not, then leaves the run `running` until the client actually exits and reports the cancellation itself. So a query that has been replaced is still running and can still finish. This is why `Pane` and `Indicator` compare `self.run == run` before doing anything, and why `Pane:stop` exists.

**Output never passes through lua.** Anything that reads a result file into a lua string reintroduces the memory cost this design exists to avoid.

**The client's output is not parsed.** What is in the file is what the client printed. `finish` appends the `[finished in 1.234s]` footer to a transcript, and writes the error message into a failed export's file. Nothing else is added, removed, or rewritten.

## Script mode and export mode

`sql.mode` reads the query to execute and decides which one to use.

Script mode runs when the format is `text`, or when the sql is anything other than a single `select`, `with`, `table`, or `values`. A script exports the native client output format to a file with the extension `log`. Stderr is merged into stdout with `2>&1`, so the client's errors appear in the order it printed them. `Pane:follow` rereads the file every 500ms, which is what makes a long script fill in as it runs.

Export mode asks the client for delimited rows on stdout, with the extension naming what it wrote, `csv` or `tsv`. Stderr stays a separate pipe so an error cannot land in the rows. The window does not open until the query ends in this case. The possible outcomes are:

- The export completes successfully, and the file is opened.
- If the export fails, `errorRows` writes the error message into the file as a single-row csv, and the file is opened.
- A cancelled export deletes its file and does not display anything.

## Connections

`b:db` is the whole of what this plugin shares with vim-dadbod and vim-dadbod-completion. Two forms of the url are in play:

- The written form, which may hold `$PGPASS` or be the name of a dadbod variable. This is what `b:db` holds, and `Pane:show` copies it onto the output buffer, so completion reads the same value everywhere.
- The resolved form from `db#resolve`, which is what the client is given. `url.withoutPassword` takes any password out of it and `client.lua` puts that password in the environment instead, because a command line is readable by every process on the machine.

`M.connect` also sets `g:db`, which is what gives the next sql buffer a connection without asking again, and calls `vim_dadbod_completion#fetch`, because that plugin reads `b:db` once per buffer and keeps what it found.

`connections.list` offers the `connections` setting when there is one, and otherwise vim-dadbod-ui's `connections.json` followed by `g:dbs`. Names already used are skipped, so neither source hides the other's entries.

## Output files

`output.directory()` returns the first of these that applies:

1. The path given to `:DBOutputDir`, for the rest of the session.
2. `output_dir` from `setup`.
3. `stdpath("cache") .. "/db-query/" .. <pid>`.

A file is named `<sql buffer basename>-<n>.<extension>`, where `n` is one past the highest number already in the directory. So running the same query twice does not write over a result still on screen, and a directory that is cleared out starts again at 1.

`output.owns(path)` returns whether the plugin should delete that file. It returns true when the file is under `output.directory()` and that directory is one the plugin clears up. The default cache location is always deleted. A custom `output_dir` set in config will be deleted unless `output_cleanup` is off, and a `:DBOutputDir` path is never automatically cleaned. `Pane:show` gives a file it owns `bufhidden = "wipe"` and a `BufWipeout` handler that removes it if the file should be deleted.

`output.sweep()` runs at `setup` and deletes cache subdirectories whose pid is no longer running. That is what covers an nvim that was killed, since a file is otherwise deleted with the window showing it. A `-o` path inside the cache root is refused, because the sweep would delete it and this behavior may seem ambiguous.

## Adding a database

Add an entry to `CLIENTS` in `lua/db-query/client.lua`, keyed by the url scheme:

```lua
CLIENTS.oracle = {
  command = function(connection, statement, mode)
    -- returns argv and extension, and optionally env, stdin, and sessionFile
  end,
}
```

`command` is called with `mode` set to one of two things:

- `"script"`: return the argv that makes the client print its own transcript, with `extension = "log"`.
- `"export"`: return the argv that writes delimited rows to stdout, with `extension` naming the delimiter, `"csv"` or `"tsv"`.

A client that cannot export rows can return its script command for both. The output then opens as text.

Add `cancel` only if the database has a server that can be asked to stop a query. It takes the connection and a session id and returns the argv that cancels. To get that session id, `command` must also return `sessionFile`, a path the client writes its own server-side id to. `client.cancel` reads the number out of that file. Without both, `Run:cancel` falls back to sending `SIGINT` to the client, which is the right thing for an embedded database like duckdb or sqlite3 that has no server to ask.
