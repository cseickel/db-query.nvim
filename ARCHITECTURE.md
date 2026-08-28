# Architecture

The query never passes through lua. The database's own client is spawned with its stdout redirected to a file, nvim opens that file in a window, and a result set large enough to exhaust nvim's memory cannot, because nvim only ever reads what the window shows.

Everything else follows from that one decision: the file needs a name, the window needs reloading while the file is still being written, and the client needs a way to be stopped.

## The components

```
   ┌──────────────────────────────────────────────────────────────┐
   │ command                                                      │
   │ :DBQuery · :DBQueryStatement · :DBConnect · :DBOutputDir     │
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
   │ settings and stateless functions                             │
   │                                                              │
   │  client  → argv · env · stdin · extension · cancel(pid)      │
   │  url     → scheme · file path · password                     │
   │  sql     → mode · statementAt · stripTerminator              │
   │  selection → the sql to run and the lines it came from       │
   │  output  → path · destination · directory · owns · sweep     │
   │  config  → what setup was given                              │
   │  connections → the list the chooser offers                   │
   └──────────────────────────────────────────────────────────────┘
```

Every arrow points down. A run holds a process and a file, and publishes one event, so a query with nothing watching it is an ordinary thing to start: `parquet` runs its `create view` through `client.run` and nothing is drawn at all.

The bottom layer holds two settings between them. `config` is what `setup` was given, and `output` is where files go, which `:DBOutputDir` changes for the session. Everything else there is a function of its arguments.

## What each one owns

**command** is what a user types. It reads the arguments once for both query commands and calls `init` with what they mean, so nothing below it parses a word.

**init** is the way in for a keymap as much as for a command. It asks `selection` which lines to run, `sql` what mode they can be run in, and the user where the output goes when they want to be asked, resolves the connection through vim-dadbod, and hands the result to the buffer's source. It holds no state.

**source** is a buffer that runs queries, and it is the only place that knows a run, a pane, and an indicator belong to the same piece of work. Its whole job is the rule that a buffer runs one query at a time.

**run** is a query in flight: the process, the file it is writing, and how it ended. `status` is `running`, `ok`, `failed`, or `cancelled`, and `onFinish` is how anything learns it changed. It knows nothing of buffers or windows.

**pane** is a window showing a file. A script's transcript rereads on a timer while the run is active, so output appears as it is written. An export opens only at the end, because partial results are not useful to render. Until the new output replaces what the window shows, what it shows is the run before, so the window is greyed through `winhighlight` while the query runs. A failed export shows the client's error written into the rows file as the one row it has, so that whatever renders csv shows the error rather than failing to parse it. A cancelled export shows nothing and its file is deleted, since half a result set that reads as a whole one is worse than no file, and no window is left holding it. A path the window has shown before is reread with `:edit`, which is a plain reread for a plain file and the refresh a plugin that renders that kind of file offers.

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

`-o` gives `output.path` a destination in place of the cache path, for that one query. `output.destination` resolves it against the working directory, and the extension is still the client's, replacing a `csv`, `tsv` or `log` already on the name rather than adding to it. An existing file is confirmed before the client starts, and a path inside the cache directory is refused, because `output.sweep` deletes what it finds there.

## Identity and lifetime

A source is a buffer. A window can show a different buffer later, and the cancel key and spinner are buffer-local, so only the buffer can own a query. Wiping the buffer cancels its query.

A pane's window is placement, not identity. It is remembered so the next query opens there, and found again when that window closes.

Cancelling is a request, so a replaced query is still running and still ends in its own time. The pane holds the run it is for and ignores any other, or a query that was replaced could take the window back from the one that replaced it.

The files this plugin makes up are named for the buffer the sql came from and numbered one past the highest number already in the directory, so that running the same query twice does not write over a result still on screen, and so that output kept beside older output does not write over that either. Nothing says where they go, and they go to a directory named for the nvim that made them:

```
~/.cache/nvim/db-query/48213/report-1.csv
                       └─pid  └─source buffer, and its run
```

A file there is deleted when the buffer showing it is wiped, so the numbering starts again at one by itself. What survives that is the output of an nvim that was killed, or that exited with a result still open, which is why `output.sweep` runs at `setup` and removes the directories whose pid is no longer running.

`:DBOutputDir` names somewhere else for the rest of the session, and `output_dir` names it once in `setup`. `output.owns` is the question everything else asks about one file: it is true while output is going somewhere this plugin clears up, which is the cache, and a configured directory unless `output_cleanup` is off, and never a directory named at runtime. A file it is false for is left as any file the user opened is left, its buffer answering to `hidden` like every other, and nothing deletes it. It is a question about the directory rather than about who named the file, so a `-o` inside a directory that is cleared up is cleared up too. The cache is the one place `-o` may not point, since the sweep would delete the file as if the plugin had made it.

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
