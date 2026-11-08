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
- **macOS row.** In `processes-list.txt`, `macOS, N processes · Apple` holds most of the
  processes (650 of 717 on testmac). A macOS row of a handful, with Apple's daemons in rows
  of their own signed by a certificate name such as `macOS Software Signing`, means Apple's
  own code is not recognised.
- **Script started by launchd.** On testmac (it loads a LaunchAgent): write
  `~/Library/LaunchAgents/local.tattle-verify.inline.plist` with `ProgramArguments`
  `/bin/zsh`, `-c`, `while :; do sleep 5; done`, `/usr/bin/true`, and `launchctl bootstrap
  gui/$(id -u)` it. Its row reads `zsh, N processes · zsh script`, not a member of `macOS`
  and not named `true`; press it, then `--prefix "zsh, pid <pid>"` when its `sleep` child
  makes it a group. The group's detail has `Signed by script, not signed`; the member's
  has `Runs with zsh (/bin/zsh)`, `Signed by script, not signed`, `Interpreter signed by
  Apple`, `Parent launchd (pid 1)`. Afterwards `launchctl bootout` it and delete the plist.
- **Standard input under launchd.** As above, with `ProgramArguments` `/bin/sh` and
  `StandardInPath` a file holding `while :; do sleep 5; done`. Its row reads `sh, 2
  processes · bash script` (macOS's `/bin/sh` runs bash), not a member of `macOS`; the
  detail has `Path /bin/bash`, `Signed by script, not signed`.
- **Python.** As above, with `/usr/bin/python3`, `-c`, `import time; [time.sleep(5) for _
  in iter(int, 1)]`. With the Command Line Tools it runs as the `Python.app` inside their
  Python framework, which is not an app: its row reads `Python, 1 process · Python script`,
  not a member of `macOS`. The detail has `Runs with Python (<path>)`, `Signed by script,
  not signed`, `Interpreter signed by Apple`, and no `Part of`.
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
- macOS row and script started by launchd proven 2026-11-07 on testmac, run
  `2026-11-07T180918` (commit `879a2ca`); run `2026-11-07T175830` is the same journeys on
  `b2a39de`, before the fix (637 rows, a macOS row of 10). Copies in this Mac's
  `build/verify/runs/testmac-2026-11-07/`.
- Standard input, Python and a script's own signer proven 2026-11-07 on testmac, run
  `2026-11-07T195705` (commit `32a5508`). Run `2026-11-07T195527` is the same journeys on
  `2fdbff2`, before them: no `sh` row, its two processes counted in `macOS` (547, against
  545 after), and the zsh group and the Python detail `Signed by Apple`.
- The Python row proven 2026-11-07 on testmac, run `2026-11-07T212351` (commit `fef4f33`);
  in run `2026-11-07T195705` (`32a5508`) it was the framework app's row, `Python, 1
  process · Apple`.
- testmac's display sleeps after a minute idle, which closes the panel and sets the
  session's `CGSSessionScreenIsLocked` with no password lock; hold `caffeinate -di` for
  the length of a run.
