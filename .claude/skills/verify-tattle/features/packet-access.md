# Packet access

Names need packets, which only root may read. Packet access installs a launch daemon, the
packet-access broker (`/Library/LaunchDaemons/io.github.eladefrati.tattle.capture-broker.plist`),
through macOS's administrator dialog, after showing the exact plist. The broker hands
Tattle a read-only capture descriptor and refuses other callers. It can be removed from
the same view or from the Startup tab. Design: `docs/adr/0003-bpf-descriptor-broker.md`.

## Sub-features

- `pa-link`: the link in the panel's footer on the Network tab reads `Packet access on` while
  capturing, else `Allow packet access` (none installed), `Packet access off` (this
  build's, not capturing), or `Packet access: install again` (another build's, another
  account's, incomplete or not loaded).
- `pa-view`: the view shows the explanation, `Capturing on en0 through the broker.` or
  `Not capturing: ...`, the plist that will be or is installed, and `Installed now:` with
  the installed one when they differ.
- `pa-install`: `Install`, `Install again` or `Install for this account` runs the dialog;
  on success the view closes and the tab shows names.
- `pa-remove`: `Remove` runs the dialog; the link becomes `Allow packet access` and the
  summary says names need packet access.
- `pa-startup-remove`: the broker's row under the daemons group in Startup has a `Remove`
  button that does the same.

## How to get to it (user POV)

- Network tab, the link in the panel's footer, then the buttons in the view.
- Startup tab, the daemons group, the broker's row, `Remove`.

## Driving it with tattle-verify

Preconditions:

- Open run; doctor all `ok`.
- The user is at the Mac to type their password. Removing the broker stops names in every copy
  running: say so when asking.

- **Before.** `$V tab Network`, `$V save pa-before`; `ls -l
  /Library/LaunchDaemons/io.github.eladefrati.tattle.capture-broker.plist`; `launchctl
  print system/io.github.eladefrati.tattle.capture-broker | head -5`.
- **Open the view.** `$V ax press --prefix "Packet access"` (or `"Allow packet access"`),
  `$V ax wait "Capturing on"` or `"Not capturing"`, `$V save pa-view`. The plist text is in
  `pa-view.txt`.
- **Remove.** `$V ax press Remove`. Stop: tell the user the administrator dialog is up and
  that it removes the broker for both copies; wait for their reply. Then: `$V log "removing
  the packet-access broker|broker removal failed"`; the plist file is gone; `launchctl
  print` fails; `$V tab Network` shows `Allow packet access` and `Destinations are
  addresses: names need packet access, which Tattle does not have yet`; `$V save
  pa-removed`.
- **Install.** `$V ax press "Allow packet access"`, `$V ax press Install`. Stop for the
  password as above. Then: `$V log "installing the packet-access broker from|packet-access
  broker installed|capturing on"` shows the install line, its path `<private>`, and a new capture line; the
  plist exists, root-owned, with `--uid 501`; the link reads `Packet access on`; `$V save
  pa-installed`.
- **Cancel.** Pressing Cancel in the dialog leaves the broker as it was and shows the error
  in the view in red; history and the plist are unchanged.

## Gotchas

- The dialog takes focus and the panel stays on screen and updating (the test Mac, 2026-11-09). A
  click outside the panel still closes it; reopen with `$V tab Network`.
- The panel's state follows the observer, not the view: after the dialog, read the result
  in the Network summary and the log, not in a stale view.
- The dev copy is signed with the team identity, so a rebuild keeps the broker's
  acceptance; an ad-hoc build is recognised by code hash and shows `install again` after
  every rebuild.
- With this build's broker installed and running, the view has only `Remove`: to prove
  Install, remove first.
- After `pa-startup-remove` the broker's row under "Allowed in the background" stays until
  the Startup tab's `Refresh`: macOS rewrites its background-items file about a minute
  after the removal, later than the tab's own refresh.
- The broker probe reaches the installed daemon with its own service name: a lookup from
  the user's session falls through to the system domain when no agent of that name runs.
  `tattle-broker-probe io.github.eladefrati.tattle.capture-broker en0`; sign copies as in
  the run below. Read the broker's lines with `/usr/bin/log show --predicate 'process
  CONTAINS "capture-broker"'`: in zsh a bare `log` is a builtin and prints nothing useful.
- XPC broker, release build of `dabba8b`, run 2026-10-26T132304: `Install again` (pressed by the user in the panel) replaced
  the installed socket broker (link `Packet access: install again` before, `Packet
  access` after; plist with `MachServices` and `--service`, root-owned, `--uid 501`;
  installed helper's cdhash equals the bundled one; legacy socket file gone; capture
  through the broker; example.com named from http). Against the installed daemon, three
  rounds (first after an idle exit, then cold, then warm): probes signed ad hoc, by the
  team under another identifier, with Tattle's identifier without the runtime, and with
  Tattle's identifier and get-task-allow are refused, each with its reason in the broker's
  log; the hardened one with Tattle's identifier is accepted. The broker exits after a
  minute idle and launchd starts it again on the next request. Its probe copies and
  entitlements plist are in `probes/`. Not replayed: the fork-and-exec attack.
- XPC broker after the 2026-10-26 review, release build of `97c85e9`, run
  2026-10-26T164905: `Install again` replaced `dabba8b`'s broker (helper cdhash
  `fa7224e3...` before, the bundled `28b03956...` after; plist root-owned with `--uid 501`
  and `--service`; no stage left; capture through the broker; example.com named from
  http). Against the installed daemon: the five probes as before (four refused, the
  hardened Tattle-identified one accepted). A no-reply message followed by a request on
  one connection: the old broker answered the second (`status 1`), the new one closes the
  connection (`Connection interrupted`); client in `clients/second-message.c`. The
  accepted probe started by `clients/inherit-launcher.c`, which hands it a bad-access
  exception port, is accepted and reports `exception-ports 0`. Twenty send-then-exec runs
  (the ad-hoc probe sends, then execs the accepted probe, which asks nothing of the broker)
  were all refused, ten after the exec had finished (-67065), with no descriptor handed.
  The broker exits after a minute idle and the next request starts it again. The root
  broker cannot be stopped from the user's account, so the deterministic stop-until-exec
  form of that check runs only in the tests.
- A launcher's exception ports after the 2026-11-07 review, dev copy of `1fca8ba` on the Mac
  with the broker installed; launcher and output in
  `build/verify/runs/2026-11-08-exception-ports/`. Started directly under a parent holding
  only a crash port, the copy captured through the broker; after `SIGABRT` the parent received
  nothing and macOS wrote the crash report. Under a parent holding only a corpse-notification
  port it received exception 13, and `thread_create` and `mach_vm_write` on that task returned
  `KERN_INVALID_ARGUMENT`. On the test Mac, with a stand-in: the old drop (`EXC_MASK_ALL`) let a
  crash-port parent write the dying child's memory (`thread_create` succeeded, but the thread
  never ran), dropping the corpse port as well left no crash report, and a corpse-port parent
  could read the dead child's memory.
- The drop at launch, after the branch review of 2026-11-08. On the test Mac, dev copies of `d370c0f`
  and `96369d1` started under an inherited stack limit by a launcher holding every exception
  port (`sweep.c`, results in `build/verify/runs/test-mac-2026-11-08/launch-drop/`). Before, from
  8 to 160 KB the startup overflowed and the launcher ran a thread in Tattle. After, from 64
  KB up it received only the dead process or nothing; at 56 KB and below the overflow is in
  the dynamic loader, before Tattle's own code, and the launcher still runs a thread there
  (ADR-0003). A stand-in linked with `-Wl,-stack_size,0x800000` ran normally at 8 KB. On the
  Mac with the broker, the dev copy of `0065d4a` under a crash-port parent captured through
  the broker, the parent received nothing after `SIGABRT`, and macOS wrote the crash report.
  lldb and xctrace before and after are in the same folder (`tools-*.txt`).
- The fixed main-thread stack (`93148ae`): the dev copy received nothing under each of 23
  stack limits from 8 KB to 1 MB, on the test Mac and on the Mac with the broker
  (`build/verify/runs/2026-11-08-exception-ports/sweep-arm64.txt`). Unpinned on that Mac,
  64 KB and below still gave a live task in the dynamic loader. The pinned dev copy, opened
  with `open`, captured through the broker.
- `pa-remove` and `pa-install` (from the view) are proven: run 2026-10-25T225118 removed
  and reinstalled the broker from the dev copy with the user's password, with every check above
  (log lines, plist gone then back root-owned with `--uid 501`, launchd job, link text).
- A downloaded release, 2026-11-11 on the test Mac (macOS 26.7.1): an ad-hoc release build made
  there, zipped, marked as a download by hand, unzipped with Archive Utility and moved to
  `/Applications` by a scripted Finder move, with no other copy or data on the Mac. macOS
  blocked it until `Open Anyway` and an administrator's password, and it then ran from a
  translocated path (`.../AppTranslocation/...`), after a quit and reopen too. From there
  `Allow packet access` installed the broker, the log read `capturing on en0 ... through the
  broker`, a request to example.com was named (`http`), and `Remove` took the daemon and its
  plist away. No run folder: the panel was driven outside a `$V` run. A move by hand in the
  Finder: the record of 2026-11-16 below.
- Install and Remove from the view, 2026-11-15 on the test Mac: an ad-hoc release build of
  `482f034`, the user typing the password in each dialog (`osascript wants to make changes.`).
  Install: the view showed the plist it would write, with this build's `cdhash` and `--uid
  502`; the log read `installing the packet-access broker from <private>`, `packet-access
  broker installed`, `capturing on en0, link type 1, through the broker`; the plist and the
  helper were root's, the daemon running, the link `Packet access on`. Remove: the plist and
  the helper gone, the daemon not loaded, the link `Allow packet access`, and the view `Not
  capturing: cannot open the packet capture device: Permission denied.` with `Install`. The
  `removing the packet-access broker` line is written when `Remove` is pressed, before the
  password: wait for the plist to go, not for the line. No run folder was kept.
- A Finder-locked file in the bundle, the same build and day: `chflags uchg` on
  `Contents/Resources/AppIcon.icns`, then `Install`. `ditto` copies the lock, so the script
  stops at `chown -R root:wheel`. The view shows the command's own line, `execution error:
  chown: /Library/PrivilegedHelperTools/.<stage>/Tattle.app/Contents/Resources/AppIcon.icns:
  Operation not permitted (1)`; the log reads `broker install failed: <private>`;
  no plist and no helper is left. Since `801fdd4` the script refuses a Finder-locked copy
  before `chown`, in a sentence of its own; that needs the test Mac's password and rests on
  `testALockedFileFailsOneInstallAndWedgesNone` (2026-11-15).
- A downloaded release by hand, 2026-11-16 on the test Mac (macOS 26.7.1, Intel): the draft
  `v2026.11.16.1`, universal and ad hoc, built by the release workflow from `850d836`. The
  user downloaded it in Chrome (zip quarantined, its SHA-256 the draft's checksum), unzipped
  it and moved it to Applications by hand in the Finder, and opened it through Open Anyway
  and an administrator's password. It ran from `/Applications/Tattle.app/Contents/MacOS/tattle`,
  not translocated: a move by hand ends translocation, where the scripted move of 2026-11-11
  did not. The running code's hash was the x86_64 slice's. `Allow packet access`, pressed by
  the user with the password: the plist and the helper root's, the daemon running,
  `/dev/bpf*` still root-only, the plist's requirement `cdhash H"<x86_64 slice>"` with
  `--uid 502`, equal to the running app's hash, and the helper the bundled universal broker
  byte for byte. The log read `installing the packet-access broker from <private>`,
  `packet-access broker installed`, `capturing on en0, link type 1, through the broker`.
  Names in Network confirmed by the user. Remove not run: the user kept the release and its
  broker installed. No run folder. The same zip worked by hand on an Apple silicon Mac
  (download, Open Anyway, the four tabs, packet access, names), as the user reported; not
  observed.
- Not proven: Cancel, `Install for this account`, and a second account
  against the installed daemon (to run on the test Mac).
