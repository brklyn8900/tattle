# Processes

The Processes tab lists running apps and programs, each app with its helpers and each
program with what it started; everything that is part of macOS is one row. Sort by
Memory or CPU. A detail shows the process's facts, an explanation, `Reveal in Finder`,
and for the user's own processes `Quit` and `Force Quit...`.

## Sub-features

- `pr-header`: `N apps and programs, M processes` and the sort segments `Memory`, `CPU`.
- `pr-group`: a group row; one with several members opens a list, one with a single
  member opens its detail.
- `pr-detail`: facts including `Process <name> (pid N)` and `Parent`, `No longer running.`
  once it exits.
- `pr-quit`: `Quit <name>` (SIGTERM), and `Force Quit...` which arms `Force Quit <name>`
  with `Cancel`; `System process` instead for others' processes.

## How to get to it (user POV)

- Click the eye, choose `Processes`, choose a row.

## Driving it with tattle-verify

Preconditions:

- Open run; doctor all `ok`.

- **List.** `$V tab Processes`, `$V ax wait "apps and programs"` (the list reads `Reading
  processes` for a few seconds), `$V save processes-list`. Compare M processes with `ps
  -A | wc -l` minus one, within a few. Rows read `"<name>, N processes · <signer>,
  <memory>, <cpu>"`; CPU is `–` until the second sample.
- **Sort.** `$V ax press CPU` (the segment; the resources line's `CPU` text is not
  pressable), wait 3 s, `$V save processes-cpu`; the rows reorder by CPU.
- **Marker process.** Start one the run owns: `nohup /bin/sleep 7777 >/dev/null 2>&1 &`
  and note its pid. It is filed under the app responsible for this terminal: press
  `--prefix "iTerm,"`. Members are listed in process-tree order, so the marker is far
  down: repeat `$V ax scroll down` until `$V ax text` has `sleep, pid <pid> · ...` (20
  pages on 2026-10-25), stop when it prints `at the end`. Press `--prefix "sleep, pid
  <pid> "`, `$V ax wait "Quit sleep"`, `$V save marker-detail`: `Process sleep (pid
  <pid>)`, `Parent launchd (pid 1)`.
- **Quit.** `$V ax press "Quit sleep"`, exact label; `ps -p <pid>` shows it gone; `$V ax
  wait "No longer running."`; `$V save marker-quit`.

## Gotchas

- Quit any process other than the run's own marker only with the user's yes.
- The group's own detail has `Quit iTerm` and `Force Quit...` for the whole app, here the
  terminal running the session. Press only the exact `Quit sleep` label inside the
  marker's detail, never a `Quit` prefix.
- The list refreshes every 3 s; wait for labels, not fixed sleeps.
- Proven 2026-10-25, run `2026-10-25T224119`; `Force Quit` not exercised.
