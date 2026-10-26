# Startup items

The Startup tab lists what starts on its own, grouped: `Open at login`, `Allowed in the
background`, your agents (`~/Library/LaunchAgents`), agents for every user
(`/Library/LaunchAgents`), daemons (`/Library/LaunchDaemons`), and `App extensions`, then
one `Apple N system jobs` row. Each row says when it runs, its state (`running, pid N`,
`not running`, `not loaded`, `disabled`, `empty file, nothing runs`) and who signed it. A
detail adds facts, an explanation, and controls.

## Sub-features

- `st-groups`: group headings with their one-line descriptions.
- `st-row`: `"<label>, <when> · <state> · <signer>"`.
- `st-detail`: facts, `Explain`, `Reveal Plist`, `Login Items Settings`.
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
- **Cross-check a row.** Pick a row from `startup-list.txt` under your agents, for
  example `ai.perplexity.CometUpdater.wake, every hour · not running · ...`. Confirm the
  plist exists in `~/Library/LaunchAgents/` and `launchctl print gui/$(id -u)/<label>`
  agrees with the state (no `pid =` line for not running).
- **Detail.** `$V ax press --prefix "<label>,"`, `$V save startup-detail`: facts, and
  `Unload` or `Load` per its state.
- **Broker row.** Under the daemons group the broker's row has `Remove`; driving it is
  packet-access.md's journey.
- **Full Disk Access.** If `startup-list.txt` has `Login items need Full Disk Access`, the
  `Open at login` and background groups are missing: record that precondition as unmet.

## Gotchas

- `Load` and `Unload` change the user's real launchd state: only with his yes, or on an agent
  the run created and removes again.
- The dev copy has its own Full Disk Access grant, separate from the release app's;
  granted 2026-10-25 (run `2026-10-25T223546` listed the login items).
- `Login Items Settings` and `Open Full Disk Access Settings` open System Settings, which
  takes the screen; avoid in unattended runs.
- Not yet proven with this skill.
