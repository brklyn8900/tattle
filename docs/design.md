# Tattle design

How Tattle is built. What it is for, who it serves and how it behaves is in the
[PRD](PRD.md); each decision that changed either is an [ADR](adr/).

## One engine, one question

Every surface runs the same pipeline on a different source:

1. **Observe**: collect raw items from the system.
2. **Identify**: attach deterministic facts: process, responsible app, code signer, owner of
   the IP block, category, the app's own declared intent.
3. **Explain**: match the item against the knowledge base; if nothing matches and the user
   clicks, ask the LLM and keep the answer.

## Sources

### Network

- The socket table with owning pid, for all users, without root, from the same `sysctl`
  (`net.inet.tcp.pcblist_n`, `net.inet.udp.pcblist_n`) that `netstat -anv` reads.
- Per-process byte counts from NetworkStatistics, the private framework behind `nettop`.
  It works unentitled today because a kernel gate is off; the tab degrades to interface
  totals if that changes.
- A BPF sniffer that reads three things and nothing else: DNS replies on port 53, to build
  an IP-to-name map; the TLS ClientHello on TCP, for the Server Name Indication; and the
  QUIC Initial packet, which carries the same ClientHello under a key derivable from the
  packet itself.

### Processes

`proc_listpids` and `proc_pidinfo`, parent pid, CPU time and memory for sorting.

Code signature via `SecCodeCopySigningInformation`: Apple, a Team ID with the organization
name read from the leaf certificate, or unsigned. Helpers are attributed to their app by
walking the parent chain and by path containment (`Slack Helper (GPU)` lives inside
`Slack.app`). macOS also tracks a "responsible process" for TCC, but the only call that
reads it is private; it is a fallback to consider if attribution gaps show up, not a
dependency.

### Ports

Listening TCP and UDP sockets with owning pid, from the same `sysctl` as Network.

### Startup

`~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`, cron and
`periodic` entries, `launchctl` state for each, and the login-items database
(`/private/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v*.btm`), which is
world-readable, undocumented, and a keyed archive with more than one schema version in the
wild; KnockKnock has a parser to learn from.

## Knowledge base

The seed knowledge base ships in the repo as JSON files, one per source, compiled into
SQLite at build time.

## LLM presets

- `claude -p`: run with `--bare --tools "" --permission-prompts none --output-format json
  --json-schema <rule schema>`; the JSON envelope's `result` field holds the answer.
- `codex exec`: it is an agent with a sandbox, so it runs in an empty working directory.
- `ollama run <model>`: reads the prompt from stdin.

## Privileges

The only privileged piece is read access to `/dev/bpf*` for the sniffer. The devices are
recreated root-only at every boot, so a one-off `chmod` does not hold. Tattle uses the same
approach as Wireshark's ChmodBPF: a small launch daemon that, at boot, creates a group,
puts the user in it, and gives that group read/write on the BPF devices. Installing and
removing it goes through the standard macOS administrator password dialog, with the exact
plist shown first. Everything else runs as the user: the socket table, the login-items
database, signatures, and launch agents need no root on current macOS. There is no
privileged helper and no `sudo`.

## Storage

SQLite through GRDB: typed records, migrations, and value observation that pushes query
results to SwiftUI when rows change, which is what every tab needs. Tables: connections
(history), items seen per tab (for "new since"), knowledge base rules, settings.

## Third-party data and licenses

| Data | Source | License | Handling |
|---|---|---|---|
| IP block owner | iptoasn.com | PDDL 1.0 | bundled |
| Domain category and owner | DuckDuckGo Tracker Radar | CC BY-NC-SA 4.0 | separate file under its own license; the app runs without it; non-commercial forks only |
| MAC vendor (later) | IEEE OUI registry | no copyright asserted | bundled |
| Apple hosts | Apple, "Use Apple products on enterprise networks" (support.apple.com/101555) | Apple copyright | facts transcribed into the seed, with the source URL and transcription date; partial and enterprise-oriented, re-checked each macOS release |
| App intent | `InternetAccessPolicy.plist` in app bundles | app's own | read from disk at runtime, only from validly signed bundles; rare (2 of 63 apps on the development machine) |

The app is MIT. The knowledge base is split-licensed by source file so the ShareAlike data
never contaminates the rest.

## Stack

Swift, SwiftUI `MenuBarExtra`, macOS 14 or later. Swift Package Manager with a script that
assembles the app bundle (Info.plist with `LSUIElement`, `codesign -s -`); no Xcode project
unless something forces one. GitHub Actions on `macos-latest` runs `swift build` and tests
on every push from the first commit.
