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
  processes` for a few seconds), `$V save processes-list`. Compare N processes with `ps
  -A | wc -l` minus one, within a few.
- **Sort.** `$V ax press CPU`, `$V save processes-cpu`; the order changes, `CPU` selected.
- **Marker process.** Start one the run owns: `/bin/sleep 7777 &` and note its pid. It is
  filed under the app responsible for this terminal (`iTerm`). Press `--prefix "iTerm,"`,
  find `sleep` (`$V ax scroll down` if needed), open it, `$V save marker-detail`: `Process
  sleep (pid <pid>)`.
- **Quit.** `$V ax press "Quit sleep"`; `ps -p <pid>` shows it gone; the detail reads `No
  longer running.`; `$V save marker-quit`.

## Gotchas

- Quit any process other than the run's own marker only with the user's yes.
- The list refreshes every 3 s; wait for labels, not fixed sleeps.
- Not yet proven with this skill.
