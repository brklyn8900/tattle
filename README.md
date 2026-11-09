# Tattle

A macOS menu bar app that shows what your Mac is doing and explains it in plain language.
It covers network connections, running processes, listening ports, and startup items. Each
item shows who signed it and, where the knowledge base or an explanation says, who runs it
and why it is probably there.

Tattle is an explainer, not a firewall and not a system monitor. It makes no network calls
of its own: no telemetry, no update check, no cloud lookups. The one way anything leaves
your machine is the **Explain** button, which sends a single redacted item to an LLM you
already have, through a command you configured. The [PRD](docs/PRD.md) says what
it does, the [design](docs/design.md) how it is built, and the [ADRs](docs/adr/) why each
decision was made.

## Status

The four tabs (Network, Processes, Ports, Startup) and Explain are built. There are no
binaries, so build from source with the steps below.

Not built yet: cron and `periodic` entries in the Startup tab, a LAN tab, per-page browser
attribution, a search bar, a "started by" filter on processes, and IP block owner data (iptoasn). The
Tracker Radar and Apple hosts knowledge files ship with no rules. Blocking is not planned.
The PRD leaves it to a future decision of its own.

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
with that identity instead, which keeps permission grants and the packet-access broker's
approval across rebuilds. To choose the identity, pass `SIGN_IDENTITY=<name>` to `make`.

## Packet access

Connection names come from the first packets of each connection, which only root may
read. **Allow packet access** in the Network tab installs the packet-access broker, a small
launch daemon that opens the capture device read-only and hands it to Tattle. The broker
answers only a process that runs as the user who installed it, carries Tattle's signature,
and runs with the hardened runtime.

You install and remove the broker through the administrator password dialog, and the
**Packet access** screen shows the exact plist first. You can also remove it from the
Startup tab, which does not show the plist. Without the broker, the
Network tab shows addresses instead of names. [ADR-0003](docs/adr/0003-bpf-descriptor-broker.md)
gives the design and the reasoning.

With an Apple Development identity, the broker recognises Tattle by its team and bundle
identifier, so it keeps accepting the release app and the dev copy after a rebuild. On a
Mac that holds that identity's signing key, any process you run can therefore obtain a
capture descriptor: it can sign a program of its own with the same identity, and the broker
accepts it. An ad-hoc build is recognised by its code hash, which changes with every
rebuild. After an ad-hoc rebuild, **Packet access** says the installed broker is from
another build and installs it again in one dialog.

Packet access is tested on macOS 26 only.

## Full Disk Access

The Startup tab reads the login-items database, which macOS puts behind Full Disk Access.
Without the grant, the tab lists launchd jobs only and says what is missing. To grant it,
click **Open Full Disk Access Settings** in the Startup tab and turn Tattle on. Nothing
else in the app needs the grant. An ad-hoc build loses it on every rebuild.
[ADR-0002](docs/adr/0002-login-items-full-disk-access.md) explains why.

## Connection history

Tattle records each connection it sees in
`~/Library/Application Support/Tattle/tattle.sqlite`: the process, its app and who signed
them, the address and port at the other end, the name it learned, and when the connection
opened and closed. That covers every process on the Mac, root's included. A row is deleted
30 days after its connection ended; **History** in Settings changes that, from 1 to 365
days. Tattle uses the record to mark an address it has not reached before; no screen lists
it yet.

The file is not encrypted, and every process you run can read it: the names the broker keeps
from them are in it, for as long as the rows last. Spotlight does not index the folder, and
Time Machine backs it up unless you exclude it.

## Explain

**Explain** sends one item to an LLM through a command you choose. Nothing is sent until
you choose a command and click **Explain** on an item.

1. Click **Settings...** in the panel.
2. Under **Explain with**, pick a preset: Claude Code (`claude -p`), Codex (`codex exec`),
   or Ollama (`ollama run llama3.2`). The tool must be installed and signed in.

To use another tool, edit **Command** so it reads the prompt on standard input and prints
the answer on standard output; the picker then shows **Custom**. Tattle replaces `{schema}` in the command
with the JSON schema the answer must match. **Output contract** in Settings shows the
schema.

Before sending, Tattle replaces these in the item and its facts with placeholders: your home
path, your username, private and local IP addresses, the Mac's names, Tailscale device names,
other accounts' folders, disk names, and a public address a port is bound to. The default
instructions go out as written. Instructions you edit lose your home path in any case, your
username, the Mac's names with either apostrophe, and private or local addresses unless
spelled with hyphens; a dotted name such as `com.username.helper`, other accounts' folders, disk
names and Tailscale names stay in them. **Last prompt sent** shows the exact text.

A name is replaced only where Tattle can tell it from an ordinary word, so some stay:

- Your home folder's path matches in any case, at the start of a path or straight after a
  disk's root; your username as a word only as written, so a login `code` leaves the app `Code`
  alone. An exact match that is the item's own name is still replaced.
- Your username stays inside a host name, next to `_` (`username_db`), and in a file named for it
  (`username.py`). In another dotted name it is replaced only as the author's part
  (`com.username.helper`): the label straight after a leading `com`, `org`, `net` or `io`, or
  after that ending in a numbered login item id (`8.com.username.helper`), with another label
  after it that is not a script's extension. So `io.github.username.tool`,
  `dev.username.tool`, `com.username` and `com.username.sh` stay.
- A username of one or two letters is replaced only before an `@`, straight after the program
  in a process title, and as the author's part. In edited instructions it stays.
- The Mac's names are replaced in a host only when the whole host is one of them, so
  `dev.azure.com` stays on a Mac called `dev`, and `dev.lan` stays unless `lan` is a search
  domain. In a startup item they are replaced only as the author's part, and in a process or
  a port they stay. Straight and curly apostrophes count as one; other spellings do not match.
- A disk's name with spaces or punctuation is replaced whole only while the disk is mounted.
  Another account's folder is replaced only at the start of a path or straight after a disk's
  root, and only up to the first space or punctuation a name rarely holds, so
  `/Users/Other User` keeps `User`.

The Claude Code preset keeps no transcript of the call and starts none of your account's
connectors, but Claude Code adds the email address it is signed in with to the request, and
Tattle cannot remove it.
The command runs in your login shell, in an empty temporary folder, and is stopped after
120 seconds. When it exits, Tattle kills what is left in its process group; a process that
left the group keeps running.

Tattle stores the answer as a rule for that item, marked unconfirmed until you click
**Confirm**. Unconfirmed answers expire after 45 days.

## Uninstall

1. If you allowed packet access, click **Remove** on the **Packet access** screen. Deleting
   the app leaves the broker's launch daemon in `/Library/LaunchDaemons`. If the app is
   already gone, remove the broker in a terminal:

       sudo launchctl bootout system/io.github.eladefrati.tattle.capture-broker
       sudo rm /Library/LaunchDaemons/io.github.eladefrati.tattle.capture-broker.plist
       sudo rm /Library/PrivilegedHelperTools/io.github.eladefrati.tattle.capture-broker

2. Delete `Tattle.app`.
3. To remove your history, rules, and settings, delete
   `~/Library/Application Support/Tattle/`. Tattle's window positions are in
   `~/Library/Preferences/io.github.eladefrati.tattle.plist`.
4. If you used Explain with the Claude Code preset, earlier versions of the preset left a
   folder per call named `*tattle-explain*` in `~/.claude/projects/`, holding the transcript,
   and in `~/Library/Caches/claude-cli-nodejs/`, holding logs. Delete those. Anything another
   command keeps is in that tool's own folders.

## License

MIT, including the knowledge base in `Resources/knowledge/`. `tracker-radar.json` and
`apple-hosts.json` ship with no rules. Tracker Radar data, once added, stays under its own
license (CC BY-NC-SA 4.0) in its own file.
