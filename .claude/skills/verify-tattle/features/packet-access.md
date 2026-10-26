# Packet access

Names need packets, which only root may read. Packet access installs a launch daemon, the
packet-access broker (`/Library/LaunchDaemons/io.github.eladefrati.tattle.capture-broker.plist`),
through macOS's administrator dialog, after showing the exact plist. The broker hands
Tattle a read-only capture descriptor and refuses other callers. It can be removed from
the same view or from the Startup tab. Design: `docs/adr/0003-bpf-descriptor-broker.md`.

## Sub-features

- `pa-link`: the Network header's link reads `Allow packet access` (none installed),
  `Packet access` (this build's, running), or `Packet access: install again` (another
  build's, another account's, incomplete or not loaded).
- `pa-view`: the view shows the explanation, `Capturing on en0 through the broker.` or
  `Not capturing: ...`, the plist that will be or is installed, and `Installed now:` with
  the installed one when they differ.
- `pa-install`: `Install`, `Install again` or `Install for this account` runs the dialog;
  on success the view closes and the tab shows names.
- `pa-remove`: `Remove` runs the dialog; the link becomes `Allow packet access` and the
  header says names need packet access.
- `pa-startup-remove`: the broker's row under the daemons group in Startup has a `Remove`
  button that does the same.

## How to get to it (user POV)

- Network tab, the link under the heading, then the buttons in the view.
- Startup tab, the daemons group, the broker's row, `Remove`.

## Driving it with tattle-verify

Preconditions:

- Open run; doctor all `ok`.
- the user is at the Mac to type his password. Removing the broker stops names in every copy
  running: say so when asking.

- **Before.** `$V tab Network`, `$V save pa-before`; `ls -l
  /Library/LaunchDaemons/io.github.eladefrati.tattle.capture-broker.plist`; `launchctl
  print system/io.github.eladefrati.tattle.capture-broker | head -5`.
- **Open the view.** `$V ax press --prefix "Packet access"` (or `"Allow packet access"`),
  `$V ax wait "Capturing on"` or `"Not capturing"`, `$V save pa-view`. The plist text is in
  `pa-view.txt`.
- **Remove.** `$V ax press Remove`. Stop: tell the user the administrator dialog is up and
  that it removes the broker for both copies; wait for his reply. Then: `$V log "removing
  the packet-access broker|broker removal failed"`; the plist file is gone; `launchctl
  print` fails; `$V tab Network` shows `Allow packet access` and `Destinations are
  addresses: names need packet access, which Tattle does not have yet`; `$V save
  pa-removed`.
- **Install.** `$V ax press "Allow packet access"`, `$V ax press Install`. Stop for the
  password as above. Then: `$V log "installing the packet-access broker from|packet-access
  broker installed|capturing on"` shows the run's bundle path and a new capture line; the
  plist exists, root-owned, with `--uid 501`; the link reads `Packet access`; `$V save
  pa-installed`.
- **Cancel.** Pressing Cancel in the dialog leaves the broker as it was and shows the error
  in the view in red; history and the plist are unchanged.

## Gotchas

- The dialog takes focus, which closes the panel; reopen with `$V tab Network`.
- The panel's state follows the observer, not the view: after the dialog, read the result
  in the Network header and the log, not in a stale view.
- The dev copy is signed with the team identity, so a rebuild keeps the broker's
  acceptance; an ad-hoc build is recognised by code hash and shows `install again` after
  every rebuild.
- With this build's broker installed and running, the view has only `Remove`: to prove
  Install, remove first.
- After `pa-startup-remove` the broker's row under "Allowed in the background" stays until
  the Startup tab's `Refresh`: macOS rewrites its background-items file about a minute
  after the removal, later than the tab's own refresh (backlog).
- The broker probe reaches the installed daemon with its own service name: a lookup from
  the user's session falls through to the system domain when no agent of that name runs.
  `tattle-broker-probe io.github.eladefrati.tattle.capture-broker en0`; sign copies as in
  the run below. Read the broker's lines with `/usr/bin/log show --predicate 'process
  CONTAINS "capture-broker"'`: in zsh a bare `log` is a builtin and prints nothing useful.
- XPC broker, release build of `470e87e`, run 2026-10-26T132304: `Install again` (pressed by the user in the panel) replaced
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
- XPC broker after the 2026-10-26 review, release build of `793d03d`, run
  2026-10-26T164905: `Install again` replaced `470e87e`'s broker (helper cdhash
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
- `pa-remove` and `pa-install` (from the view) are proven: run 2026-10-25T225118 removed
  and reinstalled the broker from the dev copy with the user's password, with every check above
  (log lines, plist gone then back root-owned with `--uid 501`, launchd job, link text).
- Socket broker, before the move to XPC: on the release build of `69e244a`, run 2026-10-25T2345-broker-final (driven with
  `tattle-ax` by hand, before `--release` existed) proved `pa-remove`, `pa-install` and
  `pa-startup-remove` (plist, helper, socket and launchd job gone), and against the
  installed daemon: broker-probe copies signed ad hoc, by the team under another
  identifier, and with Tattle's identifier without the hardened runtime are refused, the
  hardened one with Tattle's identifier is accepted; the app launched with
  `DYLD_INSERT_LIBRARIES` has it stripped by dyld and still captures; 20 connect-and-close
  cycles on the socket leave the broker's pid and run count unchanged. Its `cycles.py` and
  `inject.c` are in that run folder.
- Not proven: Cancel, `Install for this account`, and a second account
  against the installed daemon (to run on testmac).
