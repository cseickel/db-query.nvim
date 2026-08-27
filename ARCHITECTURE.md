# Architecture

The query never passes through lua. The database's own client is spawned with its stdout redirected to a file, nvim opens that file in a window, and a result set large enough to exhaust nvim's memory cannot, because nvim only ever reads what the window shows.

Everything else follows from that one decision: the file needs a name, the window needs reloading while the file is still being written, and the client needs a way to be stopped.

## The components

```
   ┌──────────────────────────────────────────────────────────────┐
   │ command                                                      │
   │ :DBQuery · :DBQueryStatement · :DBConnect                    │
   │ -f text|csv · -o path/basename                               │
   └───────────────────────────┬──────────────────────────────────┘
                               │
   ┌───────────────────────────▼──────────────────────────────────┐
   │ init                                                         │
   │ execute() · connect() · status()                             │
   └───────────────────────────┬──────────────────────────────────┘
                               │
   ┌───────────────────────────▼──────────────────────────────────┐
   │ source            one per buffer that runs queries           │
   │                                                              │
   │   run · pane · indicator                                     │
   │   rule: starting a query cancels the one it replaces         │
   └──────┬───────────────────┬─────────────────────┬─────────────┘
          │ starts            │ shows               │ attaches
          ▼                   ▼                     ▼
   ┌─ run ─────────────┐  ┌─ pane ──────────┐  ┌─ indicator ─────┐
   │ resolved · sql    │  │ srcBuf · win    │  │ buf · span · key│
   │ mode · path       │  │ shows a path    │  │ spinner · clock │
   │ status · job      │  │ rereads while   │  │ ticks while     │
   │                   │  │ status=running  │  │ status=running  │
   │ :cancel()         │  └────────┬────────┘  └────────┬────────┘
   │ :onFinish(fn)  ◄──────────────┴────────────────────┘
   └─────────┬─────────┘      both subscribe to run:onFinish()
             │ uses
             ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ stateless functions                                          │
   │                                                              │
   │  client  → argv · env · stdin · extension · cancel(pid)      │
   │  url     → scheme · file path · password                     │
   │  sql     → mode · statementAt · stripTerminator              │
   │  output  → path · destination · owns · sweep                 │
   │  config  → what setup was given                              │
   │  connections → the list the chooser offers                   │
   └──────────────────────────────────────────────────────────────┘
```

Every arrow points down. A run holds a process and a file, and publishes one event, so a query with nothing watching it is an ordinary thing to start: `parquet` runs its `create view` through `client.run` and nothing is drawn at all.

## What each one owns

**command** is what a user types. It reads the arguments once for both query commands and calls `init` with what they mean, so nothing below it parses a word.

**init** is the way in for a keymap as much as for a command. It works out which lines to run, asks `sql` what mode they can be run in, asks where the output goes when the user wants to be asked, resolves the connection through vim-dadbod, and hands the result to the buffer's source. It holds no state.

**source** is a buffer that runs queries, and it is the only place that knows a run, a pane, and an indicator belong to the same piece of work. Its whole job is the rule that a buffer runs one query at a time.

**run** is a query in flight: the process, the file it is writing, and how it ended. `status` is `running`, `ok`, `failed`, or `cancelled`, and `onFinish` is how anything learns it changed. It knows nothing of buffers or windows.

**pane** is a window showing a file. A script's transcript rereads on a timer while the run is active, so output appears as it is written. An export opens only at the end, because partial results are not useful to render. Until the new output replaces what the window shows, what it shows is the run before, so the window is greyed through `winhighlight` while the query runs. A failed export shows the client's error, written under its own name so that csv renderers do not try to parse it. A cancelled export shows nothing. After the run ends, a buffer showing a file this plugin named keeps its text and gives up its path, so that a restored session does not reference a file that was deleted. A file the user named with `-o` stays an ordinary file that `:w` writes and a session restores, and asking for the same path again rereads its buffer, so the window shows the new run rather than what was read last time.

**indicator** is what the source buffer shows while its query runs: a bar down the left edge of the lines that were sent, continuing onto a virtual line under them that holds the spinner, the clock, and the cancel key, all in `DbQueryIndicator`. All of that scrolls with the query, so it also answers `status` for a winbar, which does not. `status` also answers for the buffer a pane is showing, so a winbar over the results shows the same spinner as the one over the sql that is filling them in.

**client** holds what each database's command line tool needs, keyed by url scheme: how to run a statement, and how to stop one. An embedded database like duckdb or sqlite3 has no server, so cancelling interrupts the process.

## One query, start to finish

```
 sql ──► sql.mode ──┬── export ─► COPY … TO STDOUT ─► .csv ─► shown at the end
                    └── script ─► client transcript ─► .log ─► reread every 500ms

 b:db ─► db#resolve ─► resolved url ─► client(scheme) ─► argv · env · stdin
                                                            │
              output.path ──► <cache>/db-query/<pid>/report-1.csv
                                                            ▼
                                       sh -c 'psql …' > path   (detached)
                                                            │
                    run:cancel() ◄──────────────────────────┤
              pg_cancel_backend(pid) or SIGINT              │
                                                            ▼
                                          status · onFinish · subscribers
```

`b:db` holds the connection as it was written, which may be `$PGPASS` or a dadbod variable name. That form is what the output buffer carries, so completion and dadbod read the same thing everywhere. The client is given the resolved form instead, and any password in it is taken out of the url and put in the environment, because a command line is readable by every process on the machine.

`-o` gives `output.path` a destination of the user's in place of the cache path. `output.destination` resolves it against the working directory, the extension is still the client's, an existing file is confirmed before the client starts, and a path inside the cache directory is refused, because `output.sweep` deletes what it finds there.

## Identity and lifetime

A source is a buffer. A window can show a different buffer later, and the cancel key and spinner are buffer-local, so only the buffer can own a query. Wiping the buffer cancels its query.

A pane's window is placement, not identity. It is remembered so the next query opens there, and found again when that window closes.

Cancelling is a request, so a replaced query is still running and still ends in its own time. The pane holds the run it is for and ignores any other, or a query that was replaced could take the window back from the one that replaced it.

The files this plugin makes up are named for the buffer the sql came from, numbered so that running the same query twice does not write over a result still on screen, and kept in a directory named for the nvim that made them:

```
~/.cache/nvim/db-query/48213/report-1.csv
                       └─pid  └─source buffer, and its run
```

A file there is deleted when the buffer showing it is wiped. What survives that is the output of an nvim that was killed, or that exited with a result still open, which is why `output.sweep` runs at `setup` and removes the directories whose pid is no longer running.

A file named with `-o` is the user's, and `output.owns`, which tests whether a path is under the cache directory, is what keeps this plugin's hands off it: its buffer is not wiped when its window closes, nothing deletes the file, and a session can restore it. The same test is why `-o` may not point into the cache directory, where the sweep would delete the file as if the plugin had made it.

## Adding a database

Add a client to `CLIENTS` in `lua/db-query/client.lua`, keyed by the url scheme:

```lua
CLIENTS.oracle = {
  command = function(connection, statement, mode)
    -- argv, extension, and optionally env, stdin, sessionFile
  end,
}
```

`command` is asked for one of two shapes. In `script` mode it returns whatever the client prints for itself, with `extension = "log"`. In `export` mode it returns delimited rows on stdout, with the extension naming what it wrote, `csv` or `tsv`. A client that cannot export rows can return a script command for both, and the output opens as text.

`sessionFile` is a path the client writes its server session to, and it is what makes a query cancellable through the server. Return it only alongside a `cancel`, which is given that session and returns the command that stops it.
