# Backlog

- Notifications for what's new: an opt-in macOS notification on first contact with a
  destination, a new listening port, or a new startup item. Needs a PRD change. After the
  search bar (agreed 2026-11-07).
- Decide whether Processes, Ports and Startup should mark what is new, as Network marks first
  contact. The PRD lists what's new on every surface as a goal; only Network has it (raised
  2026-11-11).
- Decide whether facts can add a line under "Should I care", such as unsigned code or a first
  contact. Today the answer follows the rule's risk alone, so an unsigned program reaching a
  low-risk host reads "Probably not." Such facts are noisy: every build from source is
  unsigned or ad-hoc signed, and every new address is a first contact (raised 2026-11-11).
- One naming step shared by Network and Processes: Network lists processes without their
  signatures, then names each owner again.
- Confirmed program answers from before identities stay as dead rows: they have no identity,
  so they are never shown, and a confirmed rule never expires.
- An answer that was not kept stays when neither side has an identity: with none on the row,
  the detail cannot tell its code changed (`sh -c x` closes, `sh -c y` joins), so the answer
  stays until the detail closes (`ExplainSection.swift`).
- A process that replaces itself and keeps the path is not read again: `exec /bin/bash b.sh`
  from `a.sh`, or a file replaced at its path and then exec'd. Its new connections carry the
  old owner (`ConnectionOwner.unresolved`).
- A reused pid running the same program keeps the earlier process's owner, app included:
  `ConnectionOwner.unresolved` compares only the executable's path. It needs the pid to come
  round again while a connection of the earlier process is still listed. The process's start
  time (`ProcessEntry.started`) would tell the two apart.
- Resolve owners in the reading's own task. The reading already holds the owners to resolve
  and their lines, so `fold` could become synchronous: update, merge, record, publish. That
  removes the second hop off the main actor and the reread of the tracker's copy of an opened
  connection; an opening seen while owners resolve is still caught by `tracker.update`'s
  `outboundSeen`.
- `NetworkObserver.poll()` reruns itself by recursion, so under sustained traffic each
  deferred reading nests another call. A loop around the reading would not.
- Whether a known pid started another program is decided by real `proc_pidpath` and
  `KERN_PROC_PID` calls (`ConnectionOwner.unresolved` in `NetworkObserver.read()`), so tests
  steer it through the test process's own path, and the deleted-file branch has no test
  through `poll()`. Inject `executable` and `commandName` with the process records.
- The line walk (`ProcessTable.lines(of:in:parent:entry:responsible:)`) repeats
  `ProcessSnapshot.app(of:)`'s rules for which processes an app can come from. A test over
  randomized tables, resolving over the lines' entries and over the full table, would keep
  them in step.
- An owner read as `unknown process`, because the process table could not be read, is read
  again only when its pid opens another connection; its existing rows keep that owner.
- About 15% of processes that exit 26 to 42 ms after connecting lose their owner, with the
  full process sweep and with the reading by owner alike (quick-exit simulation on the test Mac,
  2026-11-10). The loss follows the lifetime, which points at the 20 ms prompt-poll delay
  (`NetworkObserver.promptPollDelay`), not at the reading.
- Inline code that calls a file is pinned by its line: `sh -c /x/agent` keeps its answer when
  `agent` changes.
- The host prompt still carries per-connection facts (`Protocol`, `Since`), and the model can
  echo them into an answer stored for the host (`NetworkSnapshot.swift`).
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
- On an Intel Mac with a T2 chip, the link to that chip (`en5` on the test Mac) counts in the rate:
  about 3 kB/s each way at rest.
- The Claude Code preset's `--system-prompt ""` relies on how the CLI treats an empty string.
  CLI 2.1.319 honors it, measured from one request; the CLI's version is not pinned and no
  repeatable check reads the request. A short non-empty prompt removes the dependency
  (`Provider.swift`).
- `posix_spawn_file_actions_addchdir_np` is deprecated in macOS 26 for
  `posix_spawn_file_actions_addchdir`, which needs macOS 26 where Tattle supports 14, so the
  new call goes behind an availability check (`Provider.swift`).
- A listener run by a JVM or a runtime `LaunchedCode` does not know (`bun`, `deno`, `dotnet`,
  `lua`) reads as the runtime, so an answer for one jar on a port is shown for another on that
  JDK. A running JVM is deliberately a program; Startup follows `java` to the jar, Ports,
  Processes and Network do not (`LaunchedCode.swift`).
- Quit signals a pid from a snapshot up to 3 s old and rechecks only the uid, so a pid reused
  in that window gets the signal (`ProcessControl.swift`). `ProcessDetail` already counts a
  reused pid as gone, by start time.
- Network's `Runs as` is the uid that created the socket, not the process's: an `sshd-session`
  running as the user read `root` (`NetworkSnapshot.swift`). Ports reads its process's.
- Two plists with one label in one domain both read as the job launchd loaded: a plist dropped
  beside a loaded job takes its state and shows `Unload`. `launchctl print <domain>/<label>`
  gives the loaded file's path (`StartupSnapshot.swift`).
- A failed read of the process table fails the whole Ports refresh, and the old list stays on
  screen with no sign: the tab shows the error only when it has no list (`PortsObserver.swift`).
- A failed read of the socket table leaves the Network list on screen with no sign, as a failed
  process read left the Processes list until it said so above the list (`NetworkTab.swift`,
  `NetworkObserver.error`).
- A one-shot listener on a port of 49152 or above is misread: once the listener has closed,
  the socket it accepted reads outbound, and its peer can count as a first contact
  (`ConnectionTracker.swift`). This Mac's SYN-ACK would prove inbound for it: the capture
  filter already passes one, and `FlowNamer` drops it.
- An agent limited to `LoginWindow` reads `not loaded` and offers `Load` in a domain it does
  not belong to: any session type other than exactly `Aqua` or `Background` falls through to
  `gui` and `user` (`LaunchdItem.domains`).
- A login item macOS has a record of and no plist is read in `gui/<uid>` only, so an agent
  limited to `Background` would read `enabled` or `off`, not `running`
  (`StartupSnapshot.loginItemState`).
- On a hosted CI runner a broker test now and then reads `transport 54` (connection reset)
  where it expects `refused`: a different test in each of three runs out of five
  (`testBrokerRefusesCallersAnotherProcessCouldSteer`, `testBrokerAnswersOnlyTheInstallingUser`,
  `testBrokerRefusesOtherCallersAndBadInterfaces`), none in the other two (2026-11-11). Not
  seen on either Mac. Unknown whether the broker closes before its refusal is delivered or
  the runner resets the connection (`CaptureBrokerTests.swift`).

**Backlog** (letters from the reflect review of 2026-10-22, cited in commit messages; (a)
and (d) are done)

- (b) A `make test` wall-clock limit with cleanup of what a killed run leaves behind. Each
  launched process already waits at most 60 s. Yes/no when raised.
- (c) Agreed (2026-10-26): on the test Mac, run the packet-access checks not yet proven (second
  account against the installed daemon, Cancel, Install for this account), then remove
  "to run on the test Mac" from `features/packet-access.md`.
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
- Processes reads as Apple's the code an Apple process runs inside itself: `jsc -e` or a
  script given to `jsc`, which the list of interpreters lacks, a vim script, a pipe into bash
  under cron (`LaunchedCode.swift`, `ProcessTable.swift`).
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
- A detail's "Interpreter signed by" and "Interpreter team" name clang, git and Xcode Service
  as interpreters, which they are not (`ProcessSnapshot.swift`).
- `ProcessEntry`'s `interpreter` and `runsUnnamedCode` are one state in two fields, which
  allows unnamed code with no interpreter: one enum would hold it (`ProcessTable.swift`).
- `testALockedFileFailsOneInstallAndWedgesNone` checks that the stage held a locked copy
  when the install failed, which holds only where ditto copies a locked file: macOS 26.7.2
  does, and on 2026-10-26 this Mac's ditto failed on it, so on such a system the check
  fails. Not run on the test Mac (26.7.1). Its name no longer fits either: the stand-in launchctl
  fails the install, not the lock (`CaptureBrokerScriptTests.swift`).
- A wrapper given no command reads as undetermined, so its launch item shows no signer,
  though some then run only their own code: `caffeinate -s` (a common keep-awake agent),
  `env`, `nice`, `time`, `arch`. Others start something else (`screen` and `script` run
  `$SHELL`), so it needs a flag per wrapper, not one rule (`LaunchedCode.swift`).
- A command line that leads through Apple's programs to none it locates (`caffeinate -s`,
  `xargs`, `open` with a document) shows no signer. It could read `launch item, not signed`,
  which claims nothing about what runs, and that would settle the wrapper line above
  (`CodeSignature.swift`).

**From the review triage of 2026-11-07** (its "consider" list, verified at `a297ef7`; IDs
are the triage's)

- A4: A signer comes from the file at the process's path, so a running program that renames
  a signed binary over its own path reads as that file's signer: a publisher's, or Apple's
  outside macOS. Only `SecCodeCheckValidity` on the running code catches it; its cost per
  process is unmeasured, and it passes a copy of one of Apple's tools made to load other
  code, which those with a team identifier do through `DYLD_` variables (the Command Line
  Tools' `lldb` did from a shell, not tried under launchd) (`CodeSignature.swift`).
- E7g: A personal Apple Development team identifier is sent to the model, twice for a
  development signer (the "Signed by" summary and the Team facts).
- K6: A DNS-only name is unmarked in the Network detail headline, against ADR-0001
  decision 2, and becomes the Explain key (`NetworkTab.swift`, `NetworkSnapshot.swift`).
- E14: Choosing Custom in the provider picker does nothing and snaps back
  (`SettingsView.swift`).
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

**From the interrogation of `fix/redaction`, 2026-11-08** (left by decision; the README says
what stays)

- A login in a file named for it goes out: `username.py` (`Redactor.swift`).
- A login next to `_` goes out: `username_development`, `backup_username.sh` (`Redactor.swift`).
- A one- or two-letter login that is also the database name is replaced only once:
  `postgres: e e [local] idle` reads `postgres: <user> e [local] idle` (`Redactor.swift`).
- Only straight and curly apostrophes count as one: a name stored with `’` misses `‘` and `ʼ`,
  and an NFC name misses its NFD spelling. No fact source producing these was found
  (`Redactor.swift`).
- A login after a hosting name goes out: `io.github.username.tool`, `com.github.username.tool`
  (`Redactor.swift`).
- Only `com`, `org`, `net` and `io` count as domain endings, so the author's part goes out
  after any other: `dev.username.tool`, `app.username.helper`, `edu.username.x`, `uk.co.username.x`
  (`Redactor.swift`).
- A startup item labelled with the login reads `<user>` in its key, while its plist keeps the
  name: `/Library/LaunchAgents/username.plist` (`Redactor.swift`).
- Coalesced QUIC Initials cost about 40 times an ordinary one. Only a local process can send
  them and the cost is bounded per datagram (`FlowNamer.swift`, `QUIC.swift`).
- The menu bar throughput label, on by default, resizes the status item as its digits change
  and goes with 8 wakeups a second against 3 with it off (`TattleApp.swift`). Correlated
  between two copies, not isolated.
- Three wakeups a second continue with the panel closed: the capture read's 500 ms timeout,
  the 1 Hz sampler and the 2-second poll. The read timeout is also how fast `stop()` takes
  effect (`Sniffer.swift`, `ResourceSampler.swift`, `NetworkObserver.swift`).
- Socket parsing formats the addresses of sockets it then drops. Check for loopback first
  (`SocketTable.swift`).
- `knownAddresses` scans all history on the main actor before the first poll: 92 ms at 204,068
  rows (`NetworkObserver.swift`, `ConnectionStore.swift`).
- `.task(id: request)` re-fires at each refresh of an open detail, and a kept answer's `stat`
  runs on the main actor, so a hung network mount would freeze the panel. Suspected, not
  reproduced (`FileDigests.swift`, `ExplainSection.swift`).
- Move the Processes loop into its observer, with `beginReadings()` inside it: only the tab's
  `.task` calls it now, and any other caller that starts a run must remember to
  (`ProcessesTab.swift`, `ProcessesObserver.swift`).
- One object for what the panel reads. A raw `state.network.snapshot` or `state.sampler.sample`
  in a panel view brings back closed-panel updates, and no test fails when it does
  (`AppState.swift`, `NetworkTab.swift`, `PanelView.swift`).
- `PortsObserver.refresh` has no overlap guard: a fast close and reopen can run two sweeps,
  and the older one can land last, for up to five seconds (`PortsObserver.swift`).
- History statements are prepared again on every call: `fetchAll(db, sql:)` and
  `execute(sql:)` compile the SQL each time, with GRDB's authorizer called for every column.
  It is most of what naming a connection still costs on the main actor: 13 of 20 ms for 22
  names in a 120-second trace (2026-11-10). Cached statements would skip it
  (`ConnectionStore.swift`).
- The app never closes the database, so quitting does not fold the log into the file: after
  `Quit Tattle` the latest changes stay in `tattle.sqlite-wal` until a later checkpoint, and
  `tattle.sqlite` alone lacks them (`AppDatabase.swift`, `TattleApp.swift`).
- Migrations run on the main thread inside `TattleApp.init`, before the menu bar item exists.
  Building the flow index took 0.25 s on the test Mac at 221,007 rows and 4.2 s
  at 3.98M, 365 days at the development Mac's rate (the real history replicated, warm cache);
  random synthetic data took 11.4 to 12.5 s at 3.8M (2026-11-10). The schema creates it on an empty database, but an index added later to a long
  history would need building after launch, from a background write (`AppDatabase.swift`).
- A large prune got slower on the main actor with the flow index and the write-ahead log. On
  the test Mac at 3.98M rows, one run per size: 1,434 rows 792 against 1,277 ms, 11,884 rows 1,602
  against 2,424 ms, 14,482 rows 1,500 against 2,545 ms; an hour's worth (291 rows) 787 against
  794 ms (2026-11-10). Most of each is the scan of every row for the cutoff, which no index
  serves. Large prunes follow a lowered retention or a long time with the app off
  (`ConnectionStore.swift`, `NetworkObserver.swift`).
- `knownAddresses` as a table scan (`NOT INDEXED`) took 0.11 s against 0.34 s through
  `connection_remote` on the test Mac at 221,007 rows, the same 5,576 addresses (2026-11-10). Then
  `connection_remote` serves nothing `connection_flow` cannot, and dropping it saves a write per
  insert and prune (12.6% fewer log frames per insert, measured by a reviewer) and about 5.4 MB
  per 211,000 rows. Dropped without the table scan, `knownAddresses` is 10% slower (327 to 339
  against 360 to 375 ms). `history(remoteAddress:)` could then order rows that share a
  `firstSeen` differently (`ConnectionStore.swift`, `AppDatabase.swift`).
- A DNS reply whose answers all point at one valid 255-byte name of four long labels still
  costs 0.26 ms on the test Mac, about 55 times the 63-byte reply and 1.5 times a real reply of the
  same size: each of its 99 names is decoded and checked in full, and the reply's bound counts
  labels and pointers, not bytes (2026-11-10). A cap on the name bytes a reply may decode, or a
  cache of names already decoded by offset, would bound it (`DNS.swift`, `HostName.swift`).
- Ordinary-looking DNS replies from a forged resolver address can keep the capture thread busy:
  88 A records in 1,462 bytes cost 0.18 ms on the test Mac, so about 5,500 such replies a second fill
  it (2026-11-10). Any host on the network can forge the resolver's address (`FlowNamer.swift`,
  `DNS.swift`).
- `ByteReader.ParseError.short` means the reply ran out of bytes, but `readName` also throws it
  for a reply over a limit: the walk limit (`DNS.swift:83`), the 64-pointer limit (`:91`) and
  the 255-byte name (`:96`). Nothing catches `.short` on its own, so the reply is refused the
  same either way; a separate case would say which.
- `ProcessTable.arguments(pid:)`, the overload without `scratch`, is called only by
  `ProcessTableTests`.

**Costs measured and left, 2026-11-10** (the test Mac, release build; the review of that day read them as
inefficient)

- A 1,400-byte segment on a finished flow costs 0.5 µs to parse and observe, 0.26 µs of it the
  parse, the same with 4,096 flows tracked: 5% of a core at 100,000 packets a second
  (`Packet.swift`, `FlowNamer.swift`).
- `expire` with 4,096 pending flows takes 0.78 ms, once a second (`FlowNamer.swift`).
- A 15 KB ClientHello takes 0.1 ms in 1,400-byte segments, 0.2 ms in 100-byte ones and 1.1 ms
  in 20-byte ones (`FlowNamer.swift`, `TLS.swift`).
- 300 connections opened at the first poll take 58 ms as a transaction each and 14 ms as one
  (`NetworkObserver.record`, `ConnectionStore.open`).
- `NetworkSnapshot.groups` takes 0.2 ms for 300 connections of 40 programs, and a render of
  the list or a group's detail asks for it up to six times (`NetworkTab.swift`).
