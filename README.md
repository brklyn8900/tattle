# Tattle

A macOS menu bar app that shows what your Mac is doing and explains it in plain language:
network connections, running processes, listening ports, and startup items, each with who
signed it and, where the knowledge base or an explanation says, who runs it and why it is
probably there.

Tattle is an explainer, not a firewall and not a system monitor. It makes no network calls
of its own: no telemetry, no update check, no cloud lookups. The one way anything leaves
your machine is an "explain" button you click, which sends a single redacted item to an LLM
you already have, through a command you configured. Design in the [proposal](docs/proposal.md);
decisions in the [ADRs](docs/adr/).

## Status

The four tabs (Network, Processes, Ports, Startup) and the explain path are built. There
are no binaries: build from source with the steps below.

Not there yet: cron and `periodic` entries in the Startup tab, a LAN tab, per-page browser
attribution, a search bar, a "started by" filter on processes, and any kind of blocking
(by design the last; see the proposal).

## Build

Requires macOS 14 or later and Xcode 26 or its command line tools.

    make app       # build, bundle and sign build/Tattle.app
    make install   # copy it to /Applications
    make test

    make run       # build and open the dev copy, build/TattleDev.app
    make stop      # quit the dev copy
    make log       # stream both copies' logs

The dev copy is a separate app, "Tattle Dev" (`io.github.eladefrati.tattle.dev`), with
its own data in `~/Library/Application Support/Tattle Dev/` and its own permission
grants, so `make run` never replaces or quits a release build that is running.

`make app` signs ad hoc. With an Apple Development identity in your keychain, it signs
with that identity instead, which keeps permission grants across rebuilds.

## Packet access

Connection names come from the first packets of each connection, which only root may
read. The Network tab's "Allow packet access" installs a small launch daemon, the
packet-access broker, that opens the capture device read-only and hands it to Tattle: it
answers only a caller that runs as the user who installed it, carries Tattle's signature,
and runs with the hardened runtime. It is installed and removed through the administrator
password dialog, with the exact plist shown first, and is removable from the Startup tab
as well. Without it the Network tab shows addresses
instead of names. Design and reasoning in [ADR-0003](docs/adr/0003-bpf-descriptor-broker.md).

With an Apple Development identity the broker recognises Tattle by team and bundle
identifier, the release app's or the dev copy's, which survive rebuilds. An ad-hoc build is recognised by its code hash, which
changes with every rebuild; Packet access then says the installed broker is from another
build and installs it again in one dialog.

Packet access is tested on macOS 26 only. The broker uses `SecCodeCreateWithXPCMessage`,
for which Apple documents no first macOS version, and it does not start on a release that
lacks the call.

## Full Disk Access

The Startup tab reads the login-items database, which macOS puts behind Full Disk Access.
Without the grant, the tab lists launchd jobs only and says what is missing. To grant it,
click **Open Full Disk Access Settings** in the Startup tab and turn Tattle on. Nothing
else in the app needs the grant. An ad-hoc build loses it on every rebuild. Reasoning in
[ADR-0002](docs/adr/0002-login-items-full-disk-access.md).

## Explain

**Explain** sends one item to an LLM through a command you choose. Nothing is sent until
you choose a command and click **Explain** on an item.

1. Click **Settings...** in the panel.
2. Under **Explain with**, pick a preset: Claude Code (`claude -p`), Codex (`codex exec`),
   or Ollama (`ollama run llama3.2`). The tool must be installed and signed in.

To use another tool, pick **Custom** and write a command that reads the prompt on standard
input and prints the answer on standard output. Tattle replaces `{schema}` in the command
with the JSON schema the answer must match, which **Output contract** shows.

Before sending, Tattle replaces your home path, your username, private and local IP
addresses, and the Mac's names with placeholders. **Last prompt sent** shows the exact text.
The command runs in your login shell, in an empty temporary folder, and is stopped after
120 seconds. Processes it leaves running are killed when it exits.

Tattle stores the answer as a rule for that item, marked unconfirmed until you click
**Confirm**. Unconfirmed answers expire after 45 days.

## Uninstall

1. If you allowed packet access, click **Remove** on the Packet access screen. Deleting the
   app leaves the broker's launch daemon in `/Library/LaunchDaemons`.
2. Delete `Tattle.app`.
3. To remove your history, rules, and settings, delete
   `~/Library/Application Support/Tattle/`.

## License

MIT, including the knowledge base in `Resources/knowledge/`. `tracker-radar.json` and
`apple-hosts.json` ship with no rules. Tracker Radar data, once added, stays under its own
license (CC BY-NC-SA 4.0) in its own file.
