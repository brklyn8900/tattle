# Processes

The Processes tab lists running apps and programs, each app with its helpers and each
program with what it started; everything that is part of macOS is one row. Sort by
Memory or CPU. A detail shows the process's facts, an explanation, `Reveal in Finder`,
and for the user's own processes `Quit` and `Force Quit…`.

## Sub-features

- `pr-header`: `N apps and programs, M processes` and the sort segments `Memory`, `CPU`.
- `pr-group`: a group row; one with several members opens a list, one with a single
  member opens its detail.
- `pr-detail`: facts including `Process <name> (pid N)` and `Parent`, `No longer running`
  once it exits.
- `pr-quit`: `Quit <name>` (SIGTERM), and `Force Quit…` which arms `Force Quit <name>`
  with `Cancel`; `Runs as <account>, so Tattle cannot quit it` instead for others'
  processes. An app's row quits the process Launch Services opened it from, or the bundle's
  main executable when Launch Services does not know it, and has no `Quit` while only its
  helpers or widgets run.

## How to get to it (user POV)

- Click the eye, choose `Processes`, choose a row.

## Driving it with tattle-verify

Preconditions:

- Open run; doctor all `ok`.

- **List.** `$V tab Processes`, `$V ax wait "apps and programs"` (the list reads `Reading
  processes` for a few seconds), `$V save processes-list`. Compare M processes with `ps
  -A | wc -l` minus one, within a few. Rows read `"<name>, N processes · <signer>,
  <memory>, <cpu>"`; CPU is `–` until the second sample, and for the first reading after the
  list was off screen.
- **macOS row.** In `processes-list.txt`, `macOS, N processes · Apple` holds most of the
  processes (650 of 717 on the test Mac). A macOS row of a handful, with Apple's daemons in rows
  of their own signed by a certificate name such as `macOS Software Signing`, means Apple's
  own code is not recognised.
- **Script started by launchd.** On the test Mac (it loads a LaunchAgent): write
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
  unnamed code`, `Interpreter signed by Apple, outside macOS`, and no `Part of`. With Xcode as the
  developer folder (`xcode-select -p`) it runs as the `Python.app` inside Xcode, whose row
  must not hold it: the row and the detail read the same. The test Mac had only the Command Line
  Tools then, so this case ran on the development Mac, with a probe the run loads and removes. A
  script that opens a window, `<dir>/window.py` (a `tkinter.Tk()` and its `mainloop()`),
  is registered by Launch Services under the framework's `Python.app` (`lsappinfo list`
  shows it): its row reads `window.py, 1 process · Python script`, and the detail has no
  `Part of`.
- **Swift.** As above, with `/usr/bin/swift`, `<dir>/loop.swift` (`import Foundation`,
  `while true { sleep(5) }`); give it 30 s to compile. It runs as `swift-frontend -frontend
  -interpret <dir>/loop.swift ...`: its row reads `loop.swift, 1 process · swift-frontend
  script`, not a member of `macOS`. The detail has `Runs with swift-frontend (<path>)`,
  `Signed by script, not signed`, `Interpreter signed by Apple, outside macOS`. The toolchain's
  `swift-frontend` with `-frontend -sdk <sdk> <dir>/loop.swift -interpret`, `-interpret`
  after the script, reads the same.
- **A compile job.** As above, with `/usr/bin/swiftc -sdk <sdk> -c <dir>/input.swift -o
  <dir>/input.o`, where `input.swift` is a `mkfifo`, so the job waits to read it. It runs
  as `swift-frontend -frontend -c -primary-file <dir>/input.swift ... -sdk <sdk> ...`: its
  row reads `swift-frontend, 1 process · swift-frontend, unnamed code`, not a member of
  `macOS`, as any of Apple's developer tools does unless it runs a script. Through Xcode's
  toolchain's `swiftc` (the development Mac) the detail has `Runs with swift-frontend (<Xcode's
  toolchain>/usr/bin/swift-frontend)`, `Signed by unnamed code`, `Interpreter signed by
  Apple, outside macOS`, `Parent launchd (pid 1)`, and no `Part of`.
- **A copy of a developer tool.** As above, with a copy of the Command Line Tools'
  `clang` in `<dir>/bin`, `-c <dir>/input.c -o <dir>/input.o`, where `input.c` is a
  `mkfifo`. The copy keeps its signing identifier, `com.apple.clang`, which reads as one of
  Apple's developer tools wherever it is: its row reads `clang, 2 processes · clang,
  unnamed code` (the driver and its `-cc1`), not a member of `macOS`.
- **An app among the developer tools.** With Xcode (the development Mac), its `Xcode Service.app`,
  under `Contents/Developer/Library/Xcode/Agents/`, while it runs: its row reads `Xcode
  Service, 1 process · unnamed code`, not its bundle's signer. The detail has `Signed by
  unnamed code`, `Interpreter signed by Apple, outside macOS`, `Interpreter team 59GAB85EFG`.
- **A developer tool reading its standard input.** Over ssh, so no app is an ancestor, with
  `/usr/bin/time /usr/bin/python3 < <dir>/in.fifo` and something holding the fifo open:
  with Xcode as the developer folder its row reads `Python, 1 process · Python, unnamed
  code`, not a member of `Xcode`. The detail has `Signed by unnamed code`, `Interpreter
  signed by Apple, outside macOS`, `Parent time (pid N)`. A shell at a terminal is still not one: a person
  may be typing.
- **An Apple-signed Xcode.** On the test Mac, whose Xcode is signed by Apple (the development Mac's is the App
  Store's and reads that): `open -ga Xcode`. Its row reads `Xcode, N processes · unnamed
  code`, its detail `Signed by unnamed code`.
- **An Apple binary moved over a running program.** On the test Mac: your own program that
  sleeps, ad hoc signed, at `/tmp/x`, started by a launch agent. Its row reads `x, 1 process
  · ad hoc signed`, its detail `Signed by ad hoc signed`. `cp /bin/ls <dir>/ls`, then `mv
  <dir>/ls /tmp/x`: the pid runs on from the file that was there. At the next refresh the row
  reads `x, 1 process · changed on disk since it started`, and it is still a row of its own,
  not a member of `macOS`. The detail has `Path /tmp/x` and no `Signed by` or `Team`. A copy
  of `/bin/sleep` moved over another such program reads the same, and so does a copy of a
  program signed with a Developer ID, where `main` named its publisher.
- **An app updated in place.** On the test Mac, with an app signed with a Developer ID open
  and the tab open: replace the bundle's main executable with another build signed by the
  same publisher. At the next refresh the app's row reads `<app>, N processes · changed on
  disk since it started`, its own process's row `pid N · changed on disk since it started`,
  and neither detail has `Signed by` or `Team`; a member whose file is untouched keeps its
  signer. Quit the app and open it again: the row reads the publisher.
- **Safari.** On the test Mac, with Safari open: its row reads `Safari, N processes · Apple`, its
  detail's path is `/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app`, and
  its WebKit helpers (`com.apple.WebKit.WebContent`, `.GPU`, `.Networking`) are its members,
  each `· Apple`.
- **A file put in a copy of one of Apple's apps.** On the test Mac: `cp -R
  /System/Applications/Calculator.app /tmp/Trusted.app`, your own ad hoc signed program copied
  to `Contents/MacOS/evil` and started by its path. The row reads `Trusted, 1 process`, with no
  signer; the process's own detail has `Signed by ad hoc signed`. macOS ends the process within
  about two seconds, so read the row at once.
- **A file put in an ad hoc signed app.** The `Tool.app` of "A file put in a bundle" in
  network-names.md, its `dropper` running: the row reads `Tool, 1 process · ad hoc signed`.
- **An app's files changed while it runs.** On the test Mac, with `Tool.app` ad hoc signed and
  running and the tab open: `mv` another program, unsigned, over `Contents/MacOS/Tool`; at the
  next refresh the row reads `Tool, 1 process · unsigned`. With the executable left as it was
  signed, write over `Contents/Info.plist` alone: at the next refresh the row reads `Tool, 1
  process · invalid signature`, its detail `Signed by invalid signature`.
- **A package by its folder.** As above, with `<node>`, `.` and `WorkingDirectory` a
  folder holding `index.js` (`setInterval(() => {}, 5000)`). The row reads `node, 1 process
  · node script`, not `.`. With node.js's own build (the test Mac's `~/.local/node`), the detail
  has `Interpreter signed by Node.js Foundation` and `Interpreter team HX7739G8FX`.
- **Sort.** `$V ax press CPU` (the segment; the resources line's `CPU` text is not
  pressable), wait 3 s, `$V save processes-cpu`; the rows reorder by CPU.
- **Marker process.** Start one the run owns: `nohup /bin/sleep 7777 >/dev/null 2>&1 &`
  and note its pid. It is filed under the app responsible for this terminal: press
  `--prefix "<terminal>,"`. Members are listed in process-tree order, so the marker is far
  down: repeat `$V ax scroll down` until `$V ax text` has `sleep, pid <pid> · ...` (20
  pages on 2026-10-25), stop when it prints `at the end`. Press `--prefix "sleep, pid
  <pid> "`, `$V ax wait "Quit sleep"`, `$V save marker-detail`: `Process sleep (pid
  <pid>)`, `Parent launchd (pid 1)`.
- **Quit.** `$V ax press "Quit sleep"`, exact label; `ps -p <pid>` shows it gone; `$V ax
  wait "No longer running"`; `$V save marker-quit`.

- **Quit on an app with a helper.** On the test Mac: `Tool.app`, ad-hoc signed with `LSUIElement`,
  whose `Contents/MacOS/Tool` runs an `NSApplication` and whose `Contents/MacOS/tool-helper`
  sleeps. Start the helper from a launch agent (`launchctl kickstart`), then `open Tool.app`,
  so the helper has the lower pid. The row reads `Tool, 2 processes · ad hoc signed`. In its
  detail `Quit Tool` ends `Tool` and leaves `tool-helper` (`ps -p`); the detail then has
  `Processes 1` and no `Quit Tool`. Afterwards `launchctl bootout` the agent and delete it.
- **Quit on an app with no window.** On the test Mac: `Tool.app`, ad-hoc signed, whose
  `Contents/MacOS/Tool` is a plain program that starts `Contents/MacOS/tool-helper`, run by a
  launch agent, so Launch Services never hears of it. The row reads `Tool, 2 processes`. In its
  detail `Quit Tool` ends `Tool` and leaves `tool-helper` (`ps -p`), and then no `Quit Tool`
  shows. Afterwards `launchctl bootout` the agent, delete it and end the helper.
- **Quit with an older run of the app's binary.** On the test Mac: `Tool.app`, ad-hoc signed with
  `LSUIElement`, whose `Contents/MacOS/Tool` runs an `NSApplication`, or only sleeps when given
  `--headless`. From one script, since a background job ends when its script's window closes:
  `Tool --headless &`, wait 3 s, `open Tool.app`. `lsappinfo info -only pid <bundle id>` names
  the opened one only. The row reads `Tool, 2 processes`. In its detail `Quit Tool` ends the
  opened one and leaves the older `--headless` (`ps -p`); the row then reads `Tool, 1 process`.
- **Another account's process.** AlDente's helper on the test Mac, which runs as root: `Runs as root,
  so Tattle cannot quit it`.

## Gotchas

- Quit only the run's own marker (SKILL.md, Stop and ask).
- The group's own detail has `Quit <terminal>` and `Force Quit…` for the whole app, here the
  terminal running the session. Press only the exact `Quit sleep` label inside the
  marker's detail, never a `Quit` prefix.
- The list refreshes every 3 s; wait for labels, not fixed sleeps.
- Proven 2026-10-25, run `2026-10-25T224119`; `Force Quit` not exercised.
- macOS row and script started by launchd proven 2026-11-07 on the test Mac, run
  `2026-11-07T180918` (commit `5fa2a4f`); run `2026-11-07T175830` is the same journeys on
  `12bc8c6`, before the fix (637 rows, a macOS row of 10). Copies in this Mac's
  `build/verify/runs/test-mac-2026-11-07/`.
- Standard input, Python and a script's own signer proven 2026-11-07 on the test Mac, run
  `2026-11-07T195705` (commit `16404e9`). Run `2026-11-07T195527` is the same journeys on
  `d0a363d`, before them: no `sh` row, its two processes counted in `macOS` (547, against
  545 after), and the zsh group and the Python detail `Signed by Apple`.
- The Python row proven 2026-11-07 on the test Mac, run `2026-11-07T212351` (commit `048af62`);
  in run `2026-11-07T195705` (`16404e9`) it was the framework app's row, `Python, 1
  process · Apple`.
- Swift, a package by its folder and the interpreter's team proven 2026-11-07 on the test Mac,
  run `2026-11-07T224519` (commit `a68ec31`). Run `2026-11-07T224338` is the same journeys
  on `9ff9cb2`, before them: no swift row (its process counted in `macOS`, 553 against 552
  after), the node row named `.`, and node's team as `Team`.
- The Python row with Xcode as the developer folder proven 2026-11-07 on the development Mac, run
  `2026-11-07T224359` (commit `a68ec31`); in run `2026-11-07T224701` (`9ff9cb2`) it was a
  member of `Xcode, 7 processes · App Store`, its detail `Part of Xcode`.
- The Tk window proven 2026-11-07 on the development Mac, run `2026-11-07T235514` (commit
  `3ed5587`); in run `2026-11-07T235435` (`6844a78`) it was the row `Python, 1 process ·
  Apple`, its detail `Part of Python`.
- The frontend with `-interpret` after its script and the swift-frontend tool proven
  2026-11-07 on the test Mac, run `2026-11-07T235929` (commit `3ed5587`). Run `2026-11-07T235754`
  is the same journeys on `6844a78`: no `loop.swift` row (its process counted in `macOS`),
  and the digester a row of its own, `Swift, 1 process · swift-frontend script`.
- The compile job proven 2026-11-08 on the test Mac, its row, run `2026-11-08T011100` (commit
  `60fda3a`); in run `2026-11-08T010801` (`0a26037`) it read `swift-frontend, 1 process ·
  swift-frontend script`. Through Xcode's toolchain on the development Mac, row and detail, run
  `2026-11-08T010935` (`60fda3a`); in run `2026-11-08T010824` (`0a26037`) it had no row of
  its own. Inline code and Python's `-c` as `unnamed code` are unit-tested only.
- The copy of clang proven 2026-11-08 on the test Mac, its row, run `2026-11-08T014224` (commit
  `0c9dd17`); in run `2026-11-08T013916` (`13b0b70`) it had no row of its own. Its detail
  was not saved. Xcode Service's row proven 2026-11-08 on the development Mac, run
  `2026-11-08T013950` (`0c9dd17`); in run `2026-11-08T013910` (`e852491`) it read `Xcode
  Service, 1 process · Apple`, its detail already `Signed by unnamed code`.
- Standard input and the Apple-signed Xcode proven 2026-11-08 on the test Mac, run
  `2026-11-08T090736` (commit `f82f06d`); in run `2026-11-08T090623` (`14501b9`) the row was
  `Xcode, 7 processes · Apple`, Python among its members, and no `Python` row.
- Quit on an app with a helper and another account's process proven 2026-11-08 on the test Mac,
  run `2026-11-08T210232` (commit `a687b73`); copy in this Mac's
  `build/verify/runs/test-mac-2026-11-08/`. Two copies of an app and a program whose worker has the lower pid rest on unit tests in
  `ProcessSnapshotTests`.
- Quit on an app with no window proven 2026-11-08 on the test Mac, run `2026-11-08T221748` (commit `b28f3cb`); copy in the development Mac's
  `build/verify/runs/test-mac-2026-11-08/`.
- Quit with an older run of the app's binary proven 2026-11-08 on the test Mac, run
  `2026-11-08T232714` (commit `13807fc`); copy in the development Mac's
  `build/verify/runs/test-mac-2026-11-08/`.
- The Apple binary moved over a running program, Safari, the file in a copy of Calculator, the
  ad hoc signed app and both changed files proven 2026-11-15 on the test Mac (commit
  `7e9f4cb`); no run folder was kept. On `main` before it the program moved over had no row
  and counted in `macOS, N processes · Apple`, and the copy's row read `Trusted, 1 process ·
  Apple`. Since Tattle checks a process's running code against its file, that program's row
  reads `changed on disk since it started` in place of `Apple, outside macOS`.
- The running-code check proven 2026-11-15 on the test Mac, at commits `8a517c1` and again
  `b882c18`: Apple's binary renamed over a running ad hoc signed program, and over a running
  unsigned one, read `<name>, 1 process · changed on disk since it started`, the detail with
  the path and no `Signed by` or `Team`. An unsigned or ad hoc signed file renamed over a
  program reads as that file's own state, since only a file that names a signer is checked.
  Publishers' apps left untouched read as on `main`. Not seen in the app: a publisher's binary
  swapped in (every Developer ID binary on the test Mac reads `invalid signature` outside its
  bundle) and an app updated in place, both resting on
  `testProcessesShowNoSignerForAProcessItsFileDoesNotVouchFor`.
- On the test Mac a copy of one of macOS's own programs (`/bin/sleep`, `/bin/ls`, `/usr/bin/nc`)
  is killed as it starts, though `codesign` finds its signature valid, so an Apple-signed file
  outside macOS is reached by moving the copy over a program that is already running. A
  program put in a copy of one of Apple's apps and started by its path ran for about two
  seconds before macOS killed it: long enough for its row, not for two to run together.
- Not seen in the app, resting on unit tests: a WebKit helper with no app above it, in the
  `macOS` row (`testWhatRunsFromACryptexIsPartOfMacOS`; every helper running was Safari's); a
  group's detail with no `Signed by` when it holds a file its app's signer did not sign
  (`testARowHoldingAFileItsAppsSignerDidNotSignNamesNoSigner`; it needs two members running);
  the grey slashed shield beside `Apple, outside macOS`
  (`testApplesSignatureOnAFileElsewhereIsNotPartOfMacOS`; the rows read carry an app icon);
  and the `Interpreter signed by Apple, outside macOS` lines above, not read in the app since
  they changed (`testAnAppAndAnInterpreterElsewhereAreNotReadAsApples`); an interpreter whose
  file is not the code it runs, whose row still reads `<interpreter> script`
  (`testProcessesShowNoSignerForAProcessItsFileDoesNotVouchFor`).
- An app row's members sit below its facts: scroll its detail (`$V ax scroll down`) before
  pressing one.
- On the development Mac the panel closed partway through two runs (`2026-11-07T224046`,
  `2026-11-07T224152`) when something else took focus; retrying each reading got through.
