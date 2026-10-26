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
- The proofs below are of the socket broker, before the move to XPC (ADR-0003). The XPC
  broker is proven by the test suite as a launchd agent in the user's domain only; none of
  the steps above has run against it as the installed daemon yet. The broker probe now
  takes a Mach service name and looks it up in the user's domain, so it cannot reach the
  installed daemon as it stands.
- `pa-remove` and `pa-install` (from the view) are proven: run 2026-10-25T225118 removed
  and reinstalled the broker from the dev copy with the user's password, with every check above
  (log lines, plist gone then back root-owned with `--uid 501`, launchd job, link text).
- On the release build of `f4b89a1`, run 2026-10-25T2345-broker-final (driven with
  `tattle-ax` by hand, before `--release` existed) proved `pa-remove`, `pa-install` and
  `pa-startup-remove` (plist, helper, socket and launchd job gone), and against the
  installed daemon: broker-probe copies signed ad hoc, by the team under another
  identifier, and with Tattle's identifier without the hardened runtime are refused, the
  hardened one with Tattle's identifier is accepted; the app launched with
  `DYLD_INSERT_LIBRARIES` has it stripped by dyld and still captures; 20 connect-and-close
  cycles on the socket leave the broker's pid and run count unchanged. Its `cycles.py` and
  `inject.c` are in that run folder.
- Not proven: Cancel, `Install again`, `Install for this account`, and a second account
  against the installed daemon (to run on testmac).
