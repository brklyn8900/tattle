# Startup items

The Startup tab lists what starts on its own, grouped: `Open at login`, `Allowed in the
background`, your agents (`~/Library/LaunchAgents`), agents for every user
(`/Library/LaunchAgents`), daemons (`/Library/LaunchDaemons`), and `App extensions`, then
one `Apple N system jobs` row. Each row says when it runs, its state (`running, pid N`,
`not running`, `not loaded`, `disabled`, `empty file, nothing runs`) and who signed it. A
detail adds facts, an explanation, and controls.

## Sub-features

- `st-groups`: group headings with their one-line descriptions.
- `st-row`: `"<name>, <when> · <state> · <signer>"`; the name is the one macOS's
  background-items record gives (`CometUpdater`), which Tattle reads only with Full Disk
  Access; otherwise, and for an agent macOS has not registered, the launchd label.
- `st-detail`: facts (`Runs`, `When`, `State`, `Signed by`, `Plist` with the path),
  `Explain`, `Reveal Plist`, `Login Items Settings`.
- `st-control`: `Load` / `Unload` for the user's own agents, `Managed by the system` for
  others, `Remove` only on Tattle's broker.
- `st-fda`: without Full Disk Access, `Login items need Full Disk Access: ...` and `Open
  Full Disk Access Settings`.

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
- **Signer of a command line.** On testmac: write these plists in `~/Library/LaunchAgents/`
  (unloaded agents are listed too; the `zsh -c` one is Processes' loaded probe), with an
  ad-hoc-signed copy of `/bin/sleep` as `agent`, and a `probe.sh` and `probe.pl` in a
  folder of the run's. Each row and its `Signed by` fact read the code that runs, never
  the interpreter or wrapper:
  - `/bin/zsh -c <code> /usr/bin/true`: `unnamed code`;
  - `/usr/bin/nohup <dir>/agent 600`: `ad hoc signed`;
  - `Program` `/bin/sh` with `ProgramArguments` `/bin/sh <dir>/probe.sh`: `Runs /bin/sh
    <dir>/probe.sh`, argv[0] not repeated, and `script, not signed`;
  - `/usr/bin/perl5.34 <dir>/probe.pl`: `script, not signed`;
  - `/bin/sh <binary>`, where the binary is a Developer ID app's (Ghostty's on testmac):
    `script, not signed`, not the app's signer;
  - `<dir>/nohup /bin/ls`, where `nohup` is a copy of `agent`: `ad hoc signed`, its own
    signer, not Apple's `ls`;
  - `<dir>/env <binary>`, with `env` a copy of `agent` and the Developer ID binary above,
    and `<dir>/nohup agent`, which names nothing on the PATH: `ad hoc signed`, their own;
  - `<dir>/h -c <code>`, where `h` is a symlink to `/bin/zsh`: `unnamed code`;
  - `/usr/bin/nohup bin/ls` with `WorkingDirectory` `<dir>`: no `Signed by`;
  - `/usr/bin/nohup sleep 600`: `Apple`, `/bin/sleep` found on the PATH;
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
    -load=<dir>/evil.dylib`, and `/usr/bin/git -C <dir> status`. With Xcode, on the user's
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
    `Apple`;
  - `/usr/bin/find <dir> -name none -exec <dir>/agent {} ;`: `ad hoc signed`;
  - `/bin/zsh -O <dir>/probe.sh /bin/ls`: `script, not signed`;
  - `/usr/bin/perl -lne /bin/ls /bin/ls`: `unnamed code`; `/usr/bin/python3 +run.py
    /bin/ls`: `script, not signed`;
  - `~/.local/node/bin/node --diagnostic-dir /usr/bin/true <dir>/evil.js`: `script, not
    signed`.
  Delete the plists and the folder afterwards.
- **Full Disk Access.** If `startup-list.txt` has `Login items need Full Disk Access`, the
  `Open at login` and background groups are missing: record that precondition as unmet.

## Gotchas

- `Load` and `Unload` change the user's real launchd state: only with his yes, or on an agent
  the run created and removes again.
- The dev copy has its own Full Disk Access grant, separate from the release app's;
  granted on the user's Mac 2026-10-25 (run `2026-10-25T223546` listed the login items). On
  any other Mac (testmac) it has none until granted there.
- `Login Items Settings` and `Open Full Disk Access Settings` open System Settings, which
  takes the screen; avoid in unattended runs.
- Proven 2026-10-25, run `2026-10-25T224119` (list, detail, cross-check, broker row);
  Load and Unload not exercised.
- Signer of a command line proven 2026-11-07 on testmac, run `2026-11-07T180918` (commit
  `879a2ca`); on `b2a39de`, run `2026-11-07T175830`, all four rows read `macOS Software
  Signing` and the Program row read `Runs /bin/sh /bin/sh ...`. Copies in this Mac's
  `build/verify/runs/testmac-2026-11-07/`.
- All of the signer journey proven again 2026-11-07 on testmac, run `2026-11-07T195705`
  (commit `32a5508`). Run `2026-11-07T195527` is the same on `2fdbff2`: the copy named
  `nohup`, the symlink, the relative path, `open` with a document, `find`, `zsh -O`, `perl
  -lne`, `python3 +run.py` and the node decoy all read `Apple`, and `nohup sleep` read
  `unsigned`.
- All of the signer journey proven again 2026-11-07 on testmac, run `2026-11-07T224519`
  (commit `9a0f53e`). Run `2026-11-07T224338` is the same on `2ec0b40`: both xargs rows
  read `Apple`, the `sh` and `env` decoys `Mitchell Hashimoto` (Ghostty's signer), the
  script files `unsigned`, the toolchain's `swift` `Apple`, `open` with a document
  `unsigned`, and `nohup agent` had no `Signed by`.
- The swift and `open` rows proven 2026-11-07 on testmac, run `2026-11-07T235929` (commit
  `2aa83fc`). Run `2026-11-07T235754` is the same on `818f035`: the `-frontend`, `swiftc`
  stub, plugin and `open -t`, `-R` and `-gR` rows read `Apple`, and the toolchain's
  `swiftc`, `swift-symbolgraph-extract` and `swift-api-digester` `script, not signed`.
- Apple's developer tools, the `-Xfrontend -interpret` script and `open`'s long options
  proven 2026-11-08 on testmac, run `2026-11-08T011100` (commit `7d50eec`). Run
  `2026-11-08T010801` is the same on `1ab9f0b`: every row `Apple` but `/usr/bin/swift
  <dir>/loop.swift`'s. The Xcode rows proven on the user's Mac, run `2026-11-08T010935`
  (`7d50eec`); in run `2026-11-08T010824` (`1ab9f0b`) the four that are not Xcode itself
  read `Apple`. The copies of `clang`, `ld` and `swift-frontend` proven on testmac, run
  `2026-11-08T014224` (`a8e6f29`); in run `2026-11-08T013916` (`d350fcc`) all four read
  `Apple`. Copies of testmac's in this Mac's `build/verify/runs/testmac-2026-11-08/`.
  Inline code as `unnamed code` (the `zsh -c`, `h -c` and `perl -lne` rows) is unit-tested
  only.
