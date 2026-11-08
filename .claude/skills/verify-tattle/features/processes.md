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
  gui/$(id -u)` it. Its row reads `zsh, N processes · zsh, unnamed code`, not a member of
  `macOS` and not named `true`; press it, then `--prefix "zsh, pid <pid>"` when its `sleep`
  child makes it a group. The group's detail has `Signed by unnamed code`; the member's
  has `Runs with zsh (/bin/zsh)`, `Signed by unnamed code`, `Interpreter signed by
  Apple`, `Parent launchd (pid 1)`. Afterwards `launchctl bootout` it and delete the plist.
- **Standard input under launchd.** As above, with `ProgramArguments` `/bin/sh` and
  `StandardInPath` a file holding `while :; do sleep 5; done`. Its row reads `sh, 2
  processes · bash script` (macOS's `/bin/sh` runs bash), not a member of `macOS`; the
  detail has `Path /bin/bash`, `Signed by script, not signed`.
- **Python.** As above, with `/usr/bin/python3`, `-c`, `import time; [time.sleep(5) for _
  in iter(int, 1)]`. With the Command Line Tools it runs as the `Python.app` inside their
  Python framework, which is not an app: its row reads `Python, 1 process · Python, unnamed
  code`, not a member of `macOS`. The detail has `Runs with Python (<path>)`, `Signed by
  unnamed code`, `Interpreter signed by Apple`, and no `Part of`. With Xcode as the
  developer folder (`xcode-select -p`) it runs as the `Python.app` inside Xcode, whose row
  must not hold it: the row and the detail read the same. testmac has only the Command Line
  Tools, so this case runs on the user's Mac, with a probe the run loads and removes. A
  script that opens a window, `<dir>/window.py` (a `tkinter.Tk()` and its `mainloop()`),
  is registered by Launch Services under the framework's `Python.app` (`lsappinfo list`
  shows it): its row reads `window.py, 1 process · Python script`, and the detail has no
  `Part of`.
- **Swift.** As above, with `/usr/bin/swift`, `<dir>/loop.swift` (`import Foundation`,
  `while true { sleep(5) }`); give it 30 s to compile. It runs as `swift-frontend -frontend
  -interpret <dir>/loop.swift ...`: its row reads `loop.swift, 1 process · swift-frontend
  script`, not a member of `macOS`. The detail has `Runs with swift-frontend (<path>)`,
  `Signed by script, not signed`, `Interpreter signed by Apple`. The toolchain's
  `swift-frontend` with `-frontend -sdk <sdk> <dir>/loop.swift -interpret`, `-interpret`
  after the script, reads the same.
- **A compile job.** As above, with `/usr/bin/swiftc -sdk <sdk> -c <dir>/input.swift -o
  <dir>/input.o`, where `input.swift` is a `mkfifo`, so the job waits to read it. It runs
  as `swift-frontend -frontend -c -primary-file <dir>/input.swift ... -sdk <sdk> ...`: its
  row reads `swift-frontend, 1 process · swift-frontend, unnamed code`, not a member of
  `macOS`, as any of Apple's developer tools does unless it runs a script. Through Xcode's
  toolchain's `swiftc` (the user's Mac) the detail has `Runs with swift-frontend (<Xcode's
  toolchain>/usr/bin/swift-frontend)`, `Signed by unnamed code`, `Interpreter signed by
  Apple`, `Parent launchd (pid 1)`, and no `Part of`.
- **A copy of a developer tool.** As above, with a copy of the Command Line Tools'
  `clang` in `<dir>/bin`, `-c <dir>/input.c -o <dir>/input.o`, where `input.c` is a
  `mkfifo`. The copy keeps its signing identifier, `com.apple.clang`, which reads as one of
  Apple's developer tools wherever it is: its row reads `clang, 2 processes · clang,
  unnamed code` (the driver and its `-cc1`), not a member of `macOS`.
- **An app among the developer tools.** With Xcode (the user's Mac), its `Xcode Service.app`,
  under `Contents/Developer/Library/Xcode/Agents/`, while it runs: its row reads `Xcode
  Service, 1 process · unnamed code`, not its bundle's signer. The detail has `Signed by
  unnamed code`, `Interpreter signed by Apple`, `Interpreter team 59GAB85EFG`.
- **A package by its folder.** As above, with `<node>`, `.` and `WorkingDirectory` a
  folder holding `index.js` (`setInterval(() => {}, 5000)`). The row reads `node, 1 process
  · node script`, not `.`. With node.js's own build (testmac's `~/.local/node`), the detail
  has `Interpreter signed by Node.js Foundation` and `Interpreter team HX7739G8FX`.
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
- Swift, a package by its folder and the interpreter's team proven 2026-11-07 on testmac,
  run `2026-11-07T224519` (commit `9a0f53e`). Run `2026-11-07T224338` is the same journeys
  on `2ec0b40`, before them: no swift row (its process counted in `macOS`, 553 against 552
  after), the node row named `.`, and node's team as `Team`.
- The Python row with Xcode as the developer folder proven 2026-11-07 on the user's Mac, run
  `2026-11-07T224359` (commit `9a0f53e`); in run `2026-11-07T224701` (`2ec0b40`) it was a
  member of `Xcode, 7 processes · App Store`, its detail `Part of Xcode`.
- The Tk window proven 2026-11-07 on the user's Mac, run `2026-11-07T235514` (commit
  `2aa83fc`); in run `2026-11-07T235435` (`818f035`) it was the row `Python, 1 process ·
  Apple`, its detail `Part of Python`.
- The frontend with `-interpret` after its script and the swift-frontend tool proven
  2026-11-07 on testmac, run `2026-11-07T235929` (commit `2aa83fc`). Run `2026-11-07T235754`
  is the same journeys on `818f035`: no `loop.swift` row (its process counted in `macOS`),
  and the digester a row of its own, `Swift, 1 process · swift-frontend script`.
- The compile job proven 2026-11-08 on testmac, its row, run `2026-11-08T011100` (commit
  `7d50eec`); in run `2026-11-08T010801` (`1ab9f0b`) it read `swift-frontend, 1 process ·
  swift-frontend script`. Through Xcode's toolchain on the user's Mac, row and detail, run
  `2026-11-08T010935` (`7d50eec`); in run `2026-11-08T010824` (`1ab9f0b`) it had no row of
  its own. Inline code and Python's `-c` as `unnamed code` are unit-tested only.
- The copy of clang proven 2026-11-08 on testmac, its row, run `2026-11-08T014224` (commit
  `a8e6f29`); in run `2026-11-08T013916` (`d350fcc`) it had no row of its own. Its detail
  was not saved. Xcode Service's row proven 2026-11-08 on the user's Mac, run
  `2026-11-08T013950` (`a8e6f29`); in run `2026-11-08T013910` (`e06b5dd`) it read `Xcode
  Service, 1 process · Apple`, its detail already `Signed by unnamed code`.
- An app row's members sit below its facts: scroll its detail (`$V ax scroll down`) before
  pressing one.
- On the user's Mac the panel closed partway through two runs (`2026-11-07T224046`,
  `2026-11-07T224152`) when something else took focus; retrying each reading got through.
- testmac's display sleeps after a minute idle, which closes the panel and sets the
  session's `CGSSessionScreenIsLocked` with no password lock; hold `caffeinate -di` for
  the length of a run.
