# Backlog

- Notifications for what's new: an opt-in macOS notification on first contact with a
  destination, a new listening port, or a new startup item. Needs a PRD change. After the
  search bar (agreed 2026-11-07).
- Invert the opt-in identity gate for rules: a rule about a program, from any source, needs
  an identity unless Apple's gate covers it. Today only `llm` rules and `builtin` rules with
  an owner do, and no shipped rule falls outside that.
- A bundle's signature is cached by the folder's modification date. Replacing an executable
  inside the bundle does not change that date, so the app's row can keep a stale reading.
- One naming step shared by Network and Processes: Network lists processes without their
  signatures, then names each owner again.
- An app's group row shows the app's signer when one of its connections comes from a foreign
  executable. The connection's own row reads right.
- Confirmed program answers from before identities stay as dead rows: they have no identity,
  so they are never shown, and a confirmed rule never expires.
- An answer that was not kept stays when neither side has an identity: with none on the row,
  the detail cannot tell its code changed (`sh -c x` closes, `sh -c y` joins), so the answer
  stays until the detail closes (`ExplainSection.swift`).
- A process that replaces itself and keeps the path is not read again: `exec /bin/bash b.sh`
  from `a.sh`, or a file replaced at its path and then exec'd. Its new connections carry the
  old owner (`ConnectionOwner.unresolved`).
- Inline code that calls a file is pinned by its line: `sh -c /x/agent` keeps its answer when
  `agent` changes.
- The host prompt still carries per-connection facts (`Protocol`, `Since`, `First contact`),
  and the model can echo them into an answer stored for the host (`NetworkSnapshot.swift`).
- A launch item's line is hashed after joining on spaces, so two argument splits collide:
  `["-c", "/x/job --dry-run"]` and `["-c", "/x/job", "--dry-run"]` (`StartupSnapshot.swift`).
- A network counter that restarts between two readings, when an interface is detached and
  attached again under the same name within one interval, reads as a 32-bit wrap: that tick
  shows up to about 4 GB/s that never moved (`NetworkCounters.delta(from:)`). A restart also
  lowers the packet counters, which a byte wrap does not (inferred: attaching an interface
  zeroes all its counters). Not observed.
- The rate counts `ppp` (L2TP, PPPoE), `vmnet`, `vnic`, `tap` and `tun` interfaces as well as
  the interface beneath them, so their bytes count twice (inferred, not observed). `ifi_type`,
  in the `if_data` the code already reads, names most layered kinds; a name list would be left
  only for kinds without a type of their own.
- The rate divides by wall-clock time (`ResourceSample.between`), so a backward clock step
  multiplies one tick by up to 1,000. A monotonic clock fixes it.
- On an Intel Mac with a T2 chip, the link to that chip (`en5` on testmac) counts in the rate:
  about 3 kB/s each way at rest.
- The Claude Code preset's `--system-prompt ""` relies on how the CLI treats an empty string.
  CLI 2.1.319 honors it, measured from one request; the CLI's version is not pinned and no
  repeatable check reads the request. A short non-empty prompt removes the dependency
  (`Provider.swift`).
- `posix_spawn_file_actions_addchdir_np` is deprecated in macOS 26 for
  `posix_spawn_file_actions_addchdir`, which needs macOS 26 where Tattle supports 14, so the
  new call goes behind an availability check (`Provider.swift`).

**Act on, from the review triage of 2026-11-07** (groups and IDs are the triage's; each fix
session ticks its lines in the commit that closes them; the docs session removes this list
once every line is ticked)

- [x] 9 (TX, T1, T2): the test target builds and the suite can gate on Xcode 27.2. fix-1-tests.
- [x] 1 (A1, A7) and 2 (A2a-e): Apple's binaries read as Apple; a command line's signer is
  the code it runs. fix-2-signer.
- [x] 3 (A3, A8): a connection is signed by its own process. fix-3-identity.
- [x] 8 (K1a, K1b): rules answer only for the identity they were given for. fix-3-identity.
- [x] 16 (K3, K4): relay rules and stale names match Apple's documentation. fix-3-identity.
- [x] 4 (B1): the exception-port drop covers EXC_CRASH; corpse notifications stay, for crash
  reports (ADR-0003). fix-4-broker-counters.
- [x] 5 (R1, R2): the network-rate sampler survives interfaces disappearing.
  fix-4-broker-counters.
- [x] 6 (E1, E3): Explain's command runs without Tattle's privacy grants; the login PATH is
  documented. fix-5-explain.
- [x] 7 (E2): the Claude Code preset keeps no transcript and loads no account connectors.
  fix-5-explain.
- [ ] 10 (E7a-h, apostrophes): redaction covers what the README promises. fix-6-redaction.
- [ ] 11 (S2): a running job reads as running. fix-7-facts.
- [ ] 12 (S1): unreadable plists are shown, not dropped. fix-7-facts.
- [ ] 13 (N1): inbound connections read as inbound. fix-7-facts.
- [ ] 14 (PR1): "Quit <App>" acts on the app. fix-7-facts.
- [ ] 15 (PR2): third-party root code is not labelled as the system. fix-7-facts.
- [ ] 17 and decisions 4-6: docs match the code. fix-8-docs.
- [ ] 18 (D6): the author's name only in author-credit fields. fix-8-docs.

**Backlog** (letters from the reflect review of 2026-10-22, cited in commit messages; (a)
and (d) are done)

- (b) A `make test` wall-clock limit with cleanup of what a killed run leaves behind. Each
  launched process already waits at most 60 s. Yes/no when raised.
- (c) Agreed (2026-10-26): on testmac, run the packet-access checks not yet proven (second
  account against the installed daemon, Cancel, Install for this account), then remove
  "to run on testmac" from `features/packet-access.md`.
- (e) After Remove, the Startup tab keeps the broker's "Allowed in the background" row until
  Refresh: its refresh runs before macOS rewrites the background-items file, about a minute
  later.
- Check whether `StartupSnapshot`'s fallback to BTM's own `teamIdentifier` (when the
  signature has none) brings back an ad-hoc item's claimed team; where BTM gets that field
  is unverified (agreed 2026-10-27).
- `LaunchedCode`'s option tables come from the manual pages, and an option they do not list
  counts as taking no value. A real option that takes one but is not listed (mostly node's
  and java's long options) makes its value read as the script: a process is then named
  after it (`LaunchedCode.swift`). A wrapper's value reads as the command it runs instead,
  and a launch item shows that file's signer: until sudo's long options were listed, `sudo
  --prompt /bin/ls /x/agent` read as `/bin/ls`. Proposed: write each table as the program's getopt string, from its manual
  page or source, and read an option no table lists as unnamed code, so an unknown option
  fails closed. With it, one table of program kinds (interpreter, launcher, wrapper, `open`,
  `find`, `xargs`) in place of the three tables and the checks by name, each kind with only
  the fields it uses: `Takes.code` now means inline code for an interpreter and a command
  not followed for a wrapper.
- In Processes, a copy of one of Apple's other tools outside its usual place keeps Apple's
  signature and reads as Apple's program, whatever it is told to load: only Apple's Swift
  tools, clang and ld are known as developer tools by signing identifier wherever they are.
  Apple's tools with a team identifier also honor `DYLD_` variables, as macOS's own programs
  do not: the Command Line Tools' `lldb` did from a shell, not tried under launchd
  (`LaunchedCode.swift`).
- Processes reads as Apple's the code an Apple process runs inside itself: `jsc -e`, a vim
  script, a pipe into bash under cron (`LaunchedCode.swift`, `ProcessTable.swift`).
- A launch item through `/usr/bin/sudo` reads as `unsigned`: sudo cannot be read by the user
  (`r-s--x--x`), so Apple's signature on it cannot be either (`CodeSignature.swift`).
- An agent an app registers with SMAppService reads by its executable: the
  `ProgramArguments` in the plist inside the app are not read (`StartupSnapshot.swift`).
- A registered agent or daemon is named by its executable with `Runs Apple's` even when
  its plist sets `RootDirectory`: a registered item's plist is not read, so the path may
  not say which file runs (`StartupSnapshot.swift`).
- A launch item with `RootDirectory` running a program that is not Apple's reads by the
  file at that path outside the root, which is not the file that runs, so the row can name
  a publisher whose code does not run. chroot needs root, so this is a daemon's
  (`CodeSignature.swift`).
- Apple-signed processes under `/Library/Developer/PrivateFrameworks` (CoreSimulatorService,
  CoreDeviceService, SimLaunchHost) read as Apple's: that folder is not one of the developer
  folders (`LaunchedCode.swift`).
- A detail's "Interpreter signed by" and "Interpreter team" name clang, git and Xcode Service
  as interpreters, which they are not (`ProcessSnapshot.swift`).
- `ProcessEntry`'s `interpreter` and `runsUnnamedCode` are one state in two fields, which
  allows unnamed code with no interpreter: one enum would hold it (`ProcessTable.swift`).
- `testALockedFileFailsOneInstallAndWedgesNone` checks that the stage held a locked copy
  when the install failed, which holds only where ditto copies a locked file: macOS 26.7.2
  does, and on 2026-10-26 this Mac's ditto failed on it, so on such a system the check
  fails. Not run on testmac (26.7.1). Its name no longer fits either: the stand-in launchctl
  fails the install, not the lock (`CaptureBrokerScriptTests.swift`).
- A wrapper given no command reads as undetermined, so its launch item shows no signer,
  though some then run only their own code: `caffeinate -s` (a common keep-awake agent),
  `env`, `nice`, `time`, `arch`. Others start something else (`screen` and `script` run
  `$SHELL`), so it needs a flag per wrapper, not one rule (`LaunchedCode.swift`).
- A command line that leads through Apple's programs to none it locates (`caffeinate -s`,
  `xargs`, `open` with a document) shows no signer. It could read `launch item, not signed`,
  which claims nothing about what runs, and that would settle the wrapper line above
  (`CodeSignature.swift`).

**From the review triage of 2026-11-07** (its "consider" list, verified at `0618f7e`; IDs
are the triage's)

- A4: A signer comes from the file at the process's path now, so a running program that
  renames an Apple binary over its own path reads as Apple. Only `SecCodeCheckValidity` on
  the running code catches it; its cost per process is unmeasured (`CodeSignature.swift`).
- E7g: A personal Apple Development team identifier is sent to the model, twice for a
  development signer (the "Signed by" summary and the Team facts).
- K6: A DNS-only name is unmarked in the Network detail headline, against ADR-0001
  decision 2, and becomes the Explain key (`NetworkTab.swift`, `NetworkSnapshot.swift`).
- E16: Retention is checked only in the UI; a stored 0 or negative value deletes every
  history row, open connections included (`AppSettings.swift`, `ConnectionStore.swift`).
- E14: Choosing Custom in the provider picker does nothing and snaps back, though the README
  says to pick it (`SettingsView.swift`).
- E4: Back and reopen during an Explain starts a second paid call; Quit leaves the provider
  and its temporary folder behind (`ExplainSection.swift`, `Provider.swift`).
- B6: The broker cancels the connection right after sending its reply, and the SDK says
  cancel discards unsent messages; a send barrier makes the order explicit
  (`tattle-capture-broker/main.c`).
- K9: A database error in the explain lookup reads as "No explanation yet"
  (`ExplainSection.swift`).
- K2: A process's own TLS server name can make its row read "relayed" or "name hidden"
  (`NetworkObserver.swift`).
- N25: A LAN peer that forges this Mac's MAC address can relabel a live UDP row; the kernel's
  direction flag (`BIOCSEXTHDR`) would stop it. Suspected, not run.
- S6: Two startup items with one label or bundle identifier share one detail view and one
  explain key (`StartupSnapshot.swift`, `StartupTab.swift`).
- S3: Login items from every account on the Mac are merged, and the first account's toggle
  wins (`LoginItems.swift`).
- S4: Apps that open at login never read "running": launchd labels them
  `application.<bundle id>.<n>.<n>` (`StartupSnapshot.swift`).
- S5: Calendar triggers read a missing key as 0, where launchd reads it as a wildcard
  (`LaunchdItem.swift`).
- P1: A port's process is the socket's last user, so socket-activated listeners show as
  launchd and an exited binder's pid can be shown (`SocketTable.swift`).
- B9: The Network header says Tattle lacks packet access while the broker is installed and
  capture fails for another reason (`PacketAccessView.swift`).
- B8: The friendly "cancelled" text for the administrator dialog is never shown, because
  osascript always writes to stderr (`CaptureBrokerInstall.swift`).
- E11: Confirm stays enabled during Ask again, and confirming then shows a raw
  `alreadyConfirmed` error (`ExplainSection.swift`).
- N8: One failed history write drops the rest of that poll's history
  (`NetworkObserver.swift`).
- N13: A failed filter rebuild keeps the old kernel filter, records the new direction, and
  logs "copying every packet" (`Sniffer.swift`).
- PR6: `ps` and `launchctl` run without a timeout; a hang would freeze the tab
  (`ProcessTable.swift`, `Launchctl.swift`).
