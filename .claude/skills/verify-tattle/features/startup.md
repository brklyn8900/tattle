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
  - `/bin/zsh -c <code> /usr/bin/true`: `script, not signed`;
  - `/usr/bin/nohup <dir>/agent 600`: `ad hoc signed`;
  - `Program` `/bin/sh` with `ProgramArguments` `/bin/sh <dir>/probe.sh`: `Runs /bin/sh
    <dir>/probe.sh`, argv[0] not repeated, and `unsigned`;
  - `/usr/bin/perl5.34 <dir>/probe.pl`: `unsigned`;
  - `<dir>/nohup /bin/ls`, where `nohup` is a copy of `agent`: `ad hoc signed`, its own
    signer, not Apple's `ls`;
  - `<dir>/h -c <code>`, where `h` is a symlink to `/bin/zsh`: `script, not signed`;
  - `/usr/bin/nohup bin/ls` with `WorkingDirectory` `<dir>`: no `Signed by`;
  - `/usr/bin/nohup sleep 600`: `Apple`, `/bin/sleep` found on the PATH;
  - `/usr/bin/open -a /System/Applications/Utilities/Terminal.app <dir>/probe.command`: no
    `Signed by`;
  - `/usr/bin/find <dir> -name none -exec <dir>/agent {} ;`: `ad hoc signed`;
  - `/bin/zsh -O <dir>/probe.sh /bin/ls`: `unsigned`, the script's;
  - `/usr/bin/perl -lne /bin/ls /bin/ls` and `/usr/bin/python3 +run.py /bin/ls`: `script,
    not signed`;
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
