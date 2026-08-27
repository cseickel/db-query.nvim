# Architecture

The query never passes through lua. The database's own client is spawned with its stdout redirected to a file, nvim opens that file in a window, and a result set large enough to exhaust nvim's memory cannot, because nvim only ever reads what the window shows.

Everything else follows from that one decision: the file needs a name, the window needs reloading while the file is still being written, and the client needs a way to be stopped.

## The components

```
   ┌──────────────────────────────────────────────────────────────┐
   │ init                                                         │
   │ :DBQuery · :DBConnect · execute() · connect()                │
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
   │ :onFinish(fn)  ◄───────────────┴───────────────────┘
   └─────────┬─────────┘      both subscribe; run knows neither
             │ uses
             ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ no state, no windows                                         │
   │                                                              │
   │  client  → argv · env · stdin · extension · cancel(pid)      │
   │  url     → scheme · file path · password                     │
   │  sql     → mode(statement) · stripTerminator                 │
   │  output  → path(source, extension) · sweep()                 │
   │  config  → what setup was given                              │
   │  connections → the list the chooser offers                   │
   └──────────────────────────────────────────────────────────────┘
```

Every arrow points down. A run holds a process and a file and publishes one event, so a query with nothing watching it is an ordinary thing to start: `parquet` runs its `create view` through `client.run` and nothing is drawn at all.

## What each one owns

**init** is the way in. It reads the lines, asks `sql` what mode they can be run in, resolves the connection through vim-dadbod, and hands the result to the buffer's source. It holds no state beyond the commands it registers.

**source** is a buffer that runs queries, and it is the only place that knows a run, a pane, and an indicator belong to the same piece of work. Its whole job is the rule that a buffer runs one query at a time.

**run** is a query in flight: the process, the file it is writing, and how it ended. `status` is `running`, `ok`, `failed`, or `cancelled`, and `onFinish` is how anything learns it changed. It knows nothing of buffers or windows.

**pane** is a window showing a file. A transcript is worth watching fill in, so it rereads on a timer while the run is going. Rows are worth reading only once they are all there, so an export opens once, at the end, and a query that failed or was cancelled opens nothing.

**indicator** is what the source buffer shows while its query runs: the lines that were sent are highlighted with `DbQueryRunning`, the spinner and the clock are drawn on a virtual line under them, and the cancel key is bound. All of that scrolls with the query, so it also answers `status` for a winbar, which does not.

**client** is what each database's command line client needs to be told, keyed by url scheme. It answers two questions per client: how to be asked to run a statement, and how the server can be asked to stop. A client that is the database rather than a client of one, such as duckdb or sqlite3, has no server to ask, and cancelling interrupts the process instead.

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
                    run:cancel() ◄───────────────────────────┤
              pg_cancel_backend(pid) or SIGINT               │
                                                             ▼
                                          status · onFinish · subscribers
```

`b:db` holds the connection as it was written, which may be `$PGPASS` or a dadbod variable name. That form is what the output buffer carries, so completion and dadbod read the same thing everywhere. The client is given the resolved form instead, and any password in it is taken out of the url and put in the environment, because a command line is readable by every process on the machine.

## Identity and lifetime

A source is a buffer. A window shows a different buffer an hour later, and the cancel key and the spinner are buffer local and cannot be told apart per window, so the buffer is the only thing that can own a query. Wiping the buffer cancels its query.

A pane's window is placement rather than identity. It is remembered so a second query lands where the first did, and resolved again whenever that window has been closed.

Cancelling is a request, so a replaced query is still running and still ends in its own time. The pane holds the run it is for and ignores any other, or a query that was replaced could take the window back from the one that replaced it.

Output files are named for the buffer the sql came from, numbered so that running the same query twice does not write over a result still on screen, and kept in a directory named for the nvim that made them:

```
~/.cache/nvim/db-query/48213/report-1.csv
                       └─pid  └─source buffer, and its run
```

A file is deleted when the buffer showing it is wiped. What survives that is the output of an nvim that was killed, or that exited with a result still open, which is why `output.sweep` runs at `setup` and removes the directories whose pid is no longer running.

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
