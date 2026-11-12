# Startup items

The Startup tab lists what starts on its own, grouped: `Open at login`, `Allowed in the
background`, your agents (`~/Library/LaunchAgents`), agents for every user
(`/Library/LaunchAgents`), daemons (`/Library/LaunchDaemons`), and `App extensions`, then
one `Apple N system jobs` row. Each row says when it runs, its state (`running, pid N`,
`not running`, `not running, last exit N`, `not loaded`, `disabled`, `on`, `off`, `empty file,
nothing runs`, `could not be read`, `could not be listed`) and who signed it. A
detail adds facts, an explanation, and controls.

## Sub-features

- `st-groups`: group headings with their one-line descriptions.
- `st-row`: `"<name>, <when> · <state> · <signer>"`; the name is the one macOS's
  background-items record gives (`CometUpdater`), which Tattle reads only with Full Disk
  Access; otherwise, and for an agent macOS has not registered, the launchd label.
- `st-detail`: facts (`Runs`, `When`, `State`, `Signed by`, `Runs Apple's` when a launch
  item that is not Apple's runs one of Apple's programs, `Plist` with the path), `Explain`,
  `Reveal Plist`, `Login Items Settings`.
- `st-control`: `Load` / `Unload` for agents, in the domain the agent loads in; `Loading or
  unloading a daemon needs root` for daemons, `Remove` only on Tattle's broker.
- `st-state`: what launchd has loaded reads as running or not running, whatever the plist's
  `Disabled` or an override says. Each job reads its own domain's state: a daemon the system
  domain, an agent `gui/<uid>`, or `user/<uid>` when its plist limits it to `Background`.
- `st-unreadable`: a plist Tattle cannot read is a row of its group, `<file name>, unknown ·
  could not be read`; the detail has `Reason` and `Reveal Plist`, and no `Explain`. With Full
  Disk Access the row takes macOS's record of the plist: its name, `Runs`, signer and
  `Explain`, still in its group, still `could not be read`.
- `st-unlisted`: a folder Tattle cannot list is a row of its group, `<folder>, unknown ·
  could not be listed`, with `Reason`, `Folder` and `Reveal Folder`. A missing folder is not.
- `st-fda`: without Full Disk Access, `Login items need Full Disk Access: ...` and `Open
  Full Disk Access Settings`.
- `st-gone`: the list is read again each time the panel opens on it. An item that left it
  while its detail was open reads `No longer installed` there, with no controls.

## How to get to it (user POV)

- Click the eye, choose `Startup`, choose a row.

## Driving it with tattle-verify

Preconditions:

- Open run; doctor all `ok`.

- **List.** `$V tab Startup`, `$V ax wait "Your agents"`, `$V save startup-list`. Each
  group heading present on this Mac is there, ending with `Apple` and `N system jobs`.
  The rows under `Your agents` match the plists in `~/Library/LaunchAgents/` one for one.
- **Detail.** Pick a row under your agents, for example `CometUpdater, every hour · not
  running · Perplexity AI Inc.`: `$V ax press --prefix "CometUpdater,"`, `$V ax wait
  "Reveal Plist"`, `$V save startup-detail`. Facts: `When every hour`, `State not
  running`, `Plist ~/Library/LaunchAgents/ai.perplexity.CometUpdater.wake.plist`; a loaded
  job has `Unload`.
- **Cross-check.** The label is the plist's file name. `launchctl print gui/$(id
  -u)/<label>` agrees: `state = not running`, `run interval = 3600 seconds`. For a row
  `not loaded` (`GoogleUpdater`), `launchctl print` fails and the detail has `Load`.
- **Broker row.** Under `Daemons`, `io.github.eladefrati.tattle.capture-broker, on demand
  · running, pid N · ...`; its detail has `Remove` (driving it is packet-access.md's
  journey; do not press it here).
- **Signer of a command line.** On the test Mac: write these plists in `~/Library/LaunchAgents/`
  (unloaded agents are listed too; the `zsh -c` one is Processes' loaded probe), with an
  ad-hoc-signed copy of `/bin/sleep` as `agent`, and a `probe.sh` and `probe.pl` in a
  folder of the run's. Each row and its `Signed by` fact read the code that runs, never
  the interpreter or wrapper:
  - `/bin/zsh -c <code> /usr/bin/true`: `unnamed code`;
  - `/usr/bin/nohup <dir>/agent 600`: `ad hoc signed`;
  - `Program` `/bin/sh` with `ProgramArguments` `/bin/sh <dir>/probe.sh`: `Runs /bin/sh
    <dir>/probe.sh`, argv[0] not repeated, and `script, not signed`;
  - `/usr/bin/perl5.34 <dir>/probe.pl`: `script, not signed`;
  - `/bin/sh <binary>`, where the binary is a Developer ID app's (Ghostty's on the test Mac):
    `script, not signed`, not the app's signer;
  - `<dir>/nohup /bin/ls`, where `nohup` is a copy of `agent`: `ad hoc signed`, its own
    signer, not Apple's `ls`;
  - `<dir>/env <binary>`, with `env` a copy of `agent` and the Developer ID binary above,
    and `<dir>/nohup agent`, which names nothing on the PATH: `ad hoc signed`, their own;
  - `<dir>/h -c <code>`, where `h` is a symlink to `/bin/zsh`: `unnamed code`;
  - `/usr/bin/nohup bin/ls` with `WorkingDirectory` `<dir>`: no `Signed by`;
  - `/usr/bin/nohup sleep 600`: `launch item, not signed`, `/bin/sleep` found on the PATH;
  - `/usr/bin/open -a /System/Applications/Utilities/Terminal.app <dir>/probe.command` and
    `/usr/bin/open <dir>/probe.command`: no `Signed by`;
  - `/usr/bin/xargs /usr/bin/open -a /System/Applications/Utilities/Terminal.app`, with
    `StandardInPath` a file naming `<dir>/probe.command`, and `/usr/bin/xargs
    /usr/bin/find <dir> -maxdepth 0`: no `Signed by`;
  - `/Library/Developer/CommandLineTools/usr/bin/swift <dir>/loop.swift` (the toolchain's
    `swift`, a symlink to `swift-frontend`) and `/usr/bin/swift <dir>/loop.swift`:
    `script, not signed`;
  - `-frontend -sdk <sdk> <dir>/loop.swift -interpret` through `/usr/bin/swift` and the
    toolchain's `swift-frontend`, `/usr/bin/swiftc -frontend -interpret <dir>/loop.swift`,
    and `/usr/bin/swiftc -wmo -typecheck -sdk <sdk> -Xfrontend -interpret
    <dir>/loop.swift`: `script, not signed`;
  - Apple's developer tools otherwise, whatever their arguments: `unnamed code`. With the
    Command Line Tools: `/usr/bin/swiftc -sdk <sdk> -c <dir>/input.swift -o
    <dir>/input.o`, loaded (Processes' compile job), `/usr/bin/swiftc -o <dir>/out
    <dir>/a.swift`, the toolchain's `swift-frontend -frontend -c <dir>/a.swift -Xllvm
    -load=<dir>/evil.dylib`, and `/usr/bin/git -C <dir> status`. With Xcode, on the development
    Mac, where macOS names each of these rows `Xcode`: Xcode's toolchain's `swiftc`, the
    same compile job through it, loaded, `xcodebuild -version` from its developer folder,
    and its `lldb-rpc-server` (in `Contents/SharedFrameworks`); Xcode's own
    `Contents/MacOS/Xcode` reads `App Store`, its signer. Copies of the Command Line
    Tools' `clang`, `ld` and `swift-frontend` in `<dir>/bin`, which keep their signing
    identifiers: `clang -c <dir>/input.c -o <dir>/input.o`, loaded, `clang
    -fplugin=<dir>/evil.dylib -c <dir>/a.c`, `ld -lto_library <dir>/evil.dylib <dir>/a.o`,
    and `swift-frontend -frontend -c <dir>/a.swift -load-plugin-library
    <dir>/evil.dylib`;
  - `/usr/bin/open -t`, `-R`, `-gR`, `--reveal`, `--rev` and `--header` with
    `/System/Applications/Calculator.app`: no `Signed by`; `/usr/bin/open -ga` with it:
    `launch item, not signed`;
  - `/usr/bin/find <dir> -name none -exec <dir>/agent {} ;`: `ad hoc signed`;
  - `/bin/zsh -O <dir>/probe.sh /bin/ls`: `script, not signed`;
  - `/usr/bin/perl -lne /bin/ls /bin/ls`: `unnamed code`; `/usr/bin/python3 +run.py
    /bin/ls`: `script, not signed`;
  - `~/.local/node/bin/node --diagnostic-dir /usr/bin/true <dir>/evil.js`: `script, not
    signed`.
  Delete the plists and the folder afterwards.
- **A launch item running Apple's program.** On the test Mac, in `~/Library/LaunchAgents/`:
  `/usr/bin/sqlite3 -cmd '.shell sleep 1197' :memory:` and `/bin/ls /`, both loaded. Each row
  reads `launch item, not signed`, not `Apple`; the detail has `Signed by launch item, not
  signed` and `Runs Apple's sqlite3` (`ls`). Apple's own jobs, under `/System/Library`, are
  counted, not listed. A helper with no plist keeps its signer: `PasswordsMenuBarExtra`
  reads `Apple`. With `RootDirectory` in the plist (`/bin/ls /`, not loaded) the row reads
  the same and the detail has no `Runs Apple's`: the path does not say which file runs.
  A copy of `/bin/ls` named `softwareupdated`, run directly, through `/usr/bin/nohup` and by
  a path out of `/usr` (`/usr/..<dir>/softwareupdated`), not loaded: the row reads the same,
  with no `Runs Apple's`. A link to `/bin/ls` named `SafariUpdater`: `Runs Apple's ls`.
  Afterwards `launchctl bootout` the two loaded agents and delete the plists.
- **xcrun.** On the test Mac, not loaded: `<dir>/lldb /bin/ls -b -s <dir>/cmds`, where `lldb` is a
  symlink to `/usr/bin/xcrun`, and `/usr/bin/xcrun ls`: `unnamed code`. `/usr/bin/xcrun swift
  <dir>/a.swift`: `script, not signed`. Delete the plists and the folder afterwards.
- **A registered item among the developer tools.** On the development Mac:
  `ProvisoningProfileQuicklookExtension.appex` (in `Xcode.app/Contents/PlugIns`) and
  `uuid.mdimporter` (in `Xcode.app/Contents/Library/Spotlight`), both signed by Apple inside
  an App Store Xcode, read `unnamed code`.
- **A job launchd has loaded.** On the test Mac, in `~/Library/LaunchAgents/`: a plist with
  `Disabled` true running `/bin/sleep 1700`, then `launchctl enable gui/$(id -u)/<label>`,
  `launchctl bootstrap` and `launchctl kickstart`. The row and `State` read `running, pid N`;
  the detail has `Unload`. Afterwards `launchctl bootout` it and delete the plist.
- **A plist that cannot be read.** On the test Mac, in `~/Library/LaunchAgents/`: a valid plist with
  mode 000, and a file holding `junk`. Each row reads `<file name>, unknown · could not be
  read`; `Reason` is `Tattle has no permission to read this file` and `it is not a launchd
  job`, and neither detail has `Explain`. Afterwards delete both.
- **A plist macOS has a record of.** With Full Disk Access, on the development Mac: a plist
  the run writes to `~/Library/LaunchAgents/`, bootstrapped. Refresh until its detail has
  `Login Items Settings` (macOS named the row `sleep`), `chmod 000` it, Refresh. The row,
  under `Your agents`, reads `sleep, unknown · could not be read · launch item, not signed`;
  the detail has `Runs /bin/sleep`, `Reason`, `Explain` and `Login Items Settings`. Afterwards
  restore the mode, `launchctl bootout` it and delete it.
- **A folder that cannot be listed.** On the test Mac: `chmod 000 ~/Library/LaunchAgents`, press
  `Refresh`. `LaunchAgents, unknown · could not be listed`, with `Reason Tattle has no
  permission to list this folder`, `Folder` and `Reveal Folder`, no `Explain`. Restore the
  mode at once.
- **An agent in the Background session.** On the test Mac: a plist with `LimitLoadToSessionType`
  `Background` and `RunAtLoad`, `launchctl bootstrap user/$(id -u)`. The row reads `running,
  pid N`. `Unload` removes it from `user/<uid>` and the row reads `not loaded`; `Load` puts
  it back. Afterwards `launchctl bootout` it and delete the plist.
- **A daemon's controls.** Under `Daemons`, a third party's (AlDente's helper on the test Mac): `Loading
  or unloading a daemon needs root`.
- **Full Disk Access.** If `startup-list.txt` has `Login items need Full Disk Access`, the
  `Open at login` and background groups are missing: record that precondition as unmet.

## Gotchas

- `Load` and `Unload` only on an agent the run created and removes again (SKILL.md, Stop and
  ask).
- The dev copy has its own Full Disk Access grant, separate from the release app's;
  granted on the development Mac 2026-10-25 (run `2026-10-25T223546` listed the login items). On
  any other Mac (the test Mac) it has none until granted there.
- `Login Items Settings` and `Open Full Disk Access Settings` open System Settings, which
  takes the screen; avoid in unattended runs.
- Proven 2026-10-25, run `2026-10-25T224119` (list, detail, cross-check, broker row);
  Load and Unload not exercised.
- Signer of a command line proven 2026-11-07 on the test Mac, run `2026-11-07T180918` (commit
  `5fa2a4f`); on `12bc8c6`, run `2026-11-07T175830`, all four rows read `macOS Software
  Signing` and the Program row read `Runs /bin/sh /bin/sh ...`. Copies in this Mac's
  `build/verify/runs/test-mac-2026-11-07/`.
- All of the signer journey proven again 2026-11-07 on the test Mac, run `2026-11-07T195705`
  (commit `16404e9`). Run `2026-11-07T195527` is the same on `d0a363d`: the copy named
  `nohup`, the symlink, the relative path, `open` with a document, `find`, `zsh -O`, `perl
  -lne`, `python3 +run.py` and the node decoy all read `Apple`, and `nohup sleep` read
  `unsigned`.
- All of the signer journey proven again 2026-11-07 on the test Mac, run `2026-11-07T224519`
  (commit `a68ec31`). Run `2026-11-07T224338` is the same on `9ff9cb2`: both xargs rows
  read `Apple`, the `sh` and `env` decoys `Mitchell Hashimoto` (Ghostty's signer), the
  script files `unsigned`, the toolchain's `swift` `Apple`, `open` with a document
  `unsigned`, and `nohup agent` had no `Signed by`.
- The swift and `open` rows proven 2026-11-07 on the test Mac, run `2026-11-07T235929` (commit
  `3ed5587`). Run `2026-11-07T235754` is the same on `6844a78`: the `-frontend`, `swiftc`
  stub, plugin and `open -t`, `-R` and `-gR` rows read `Apple`, and the toolchain's
  `swiftc`, `swift-symbolgraph-extract` and `swift-api-digester` `script, not signed`.
- Apple's developer tools, the `-Xfrontend -interpret` script and `open`'s long options
  proven 2026-11-08 on the test Mac, run `2026-11-08T011100` (commit `60fda3a`). Run
  `2026-11-08T010801` is the same on `0a26037`: every row `Apple` but `/usr/bin/swift
  <dir>/loop.swift`'s. The Xcode rows proven on the development Mac, run `2026-11-08T010935`
  (`60fda3a`); in run `2026-11-08T010824` (`0a26037`) the four that are not Xcode itself
  read `Apple`. The copies of `clang`, `ld` and `swift-frontend` proven on the test Mac, run
  `2026-11-08T014224` (`0c9dd17`); in run `2026-11-08T013916` (`13b0b70`) all four read
  `Apple`. Copies of the test Mac's in this Mac's `build/verify/runs/test-mac-2026-11-08/`.
  Inline code as `unnamed code` (the `zsh -c`, `h -c` and `perl -lne` rows) is unit-tested
  only.
- The launch item rule and xcrun proven 2026-11-08 on the test Mac, run `2026-11-08T090736` (commit
  `f82f06d`). In run `2026-11-08T090623` (`14501b9`) the `sqlite3`, `ls` and two xcrun rows
  read `Apple`. The registered items proven on the development Mac, run `2026-11-08T090639`
  (`f82f06d`); in run `2026-11-08T090557` (`14501b9`) they read `Apple`. The `open -ga` row
  is unit-tested at this reading, not run again. `RootDirectory` proven on the test Mac, run
  `2026-11-08T092645` (`6a81d7a`); in run `2026-11-08T092551` (`db98bda`) its detail had
  `Runs Apple's ls`.
  The copy, the link and the path out of `/usr` proven on the test Mac, run `2026-11-08T100408`
  (`d8825b4`); in run `2026-11-08T100308` (`da67eac`) they had `Runs Apple's softwareupdated`
  and `Runs Apple's SafariUpdater`.
- The loaded job, the plists that cannot be read and the daemon's words proven 2026-11-08 on
  the test Mac, run `2026-11-08T210232` (commit `a687b73`); copy in this Mac's
  `build/verify/runs/test-mac-2026-11-08/`. An agent and a daemon sharing a label rest on the unit test
  (`testEachDomainAnswersForItsOwnJobs`).
- A folder that cannot be listed and the Background agent, its `Unload` and `Load` included,
  proven 2026-11-08 on the test Mac, run `2026-11-08T221748` (commit `b28f3cb`); copy in the development Mac's
  `build/verify/runs/test-mac-2026-11-08/`. A plist macOS has a record of proven 2026-11-08 on
  the development Mac, run `2026-11-08T222028` (`b28f3cb`). A record of a kind Tattle does not
  list rests on the unit test (`testARecordOfAnUnknownKindDoesNotHideAnUnreadablePlist`).
- `st-gone` proven 2026-11-10 on the test Mac, dev copy at `0b1e7c9`, run `2026-11-10T191945`: an
  agent's plist, not loaded, deleted under its open detail; the panel closed and opened, with
  no `Refresh`: `No longer installed.` and `Load` gone. Copy in the development Mac's
  `build/verify/runs/test-mac-2026-11-10/`. Not driven: the broker's row after `Remove`.
