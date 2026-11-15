# Tattle design

How Tattle is built. What it is for, who it serves and how it behaves is in the
[PRD](PRD.md); each decision that changed either is an [ADR](adr/).

## One engine, one question

Every surface runs the same pipeline on a different source:

1. **Observe**: collect raw items from the system.
2. **Identify**: attach deterministic facts: process, responsible app, code signer.
3. **Explain**: match the item against the knowledge base; if nothing matches and the user
   clicks, ask the LLM and keep the answer.

## Sources

### Network

- The socket table with owning pid, for all users, without root, from the same `sysctl`
  (`net.inet.tcp.pcblist_n`, `net.inet.udp.pcblist_n`) that `netstat -anv` reads.
- Bytes in and out per interface, from `getifaddrs`, for the menu bar and the resources
  line. There are no per-process byte counts.
- A BPF sniffer that reads four things and nothing else: DNS replies on port 53, to build
  an IP-to-name map; the TLS ClientHello on TCP, for the Server Name Indication; the QUIC
  Initial packet, which carries the same ClientHello under a key derivable from the packet
  itself; and the Host header of a plaintext HTTP request. A name from the wire wins; the DNS map is a fallback
  ([ADR-0001](adr/0001-sniffer-coverage.md)). The sniffer gets its capture descriptor from
  the broker (Privileges).

### Processes

The process list and parent pids from the `KERN_PROC_ALL` `sysctl`; paths from
`proc_pidpath`; CPU time and memory for sorting from `proc_pid_rusage`, and from `/bin/ps`
for the processes that call will not describe; the working directory from `proc_pidinfo`.

Code signature via `SecCodeCopySigningInformation`: Apple, a Team ID with the organization
name read from the leaf certificate, or unsigned. Apple's signature reads as Apple's only on
a file where only macOS installs programs (the system volume's folders and `/Library/Apple`);
on a file anywhere else it reads as Apple's outside macOS, and its process is not part of
the macOS row. Helpers are attributed to their app by
walking the parent chain and by path containment (`Slack Helper (GPU)` lives inside
`Slack.app`). A service launchd started for an app has neither, so it is filed under the
"responsible process" macOS tracks for TCC, which only a private call reads
([ADR-0004](adr/0004-process-responsibility-private-calls.md)).

### Ports

Listening TCP and UDP sockets with owning pid, from the same `sysctl` as Network.

### Startup

`~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`, `launchctl`
state for each, and the login-items database
(`/private/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v*.btm`), which needs
Full Disk Access ([ADR-0002](adr/0002-login-items-full-disk-access.md)), is undocumented,
and is a keyed archive with more than one schema version in the wild; it is decoded with a
generic record class in place of the private ones (`Startup/LoginItems.swift`).

## Knowledge base

The seed knowledge base ships in the repo as JSON files, one per source. They are copied
into the app bundle and loaded into SQLite at launch, each only when its content changed.

## LLM presets

The commands, and why each flag is there, are `ShellProvider.presets` in
`Sources/tattle/Explain/Provider.swift`.

## Privileges

The only privileged piece is packet access for the sniffer. `/dev/bpf*` stays root-only. A
descriptor broker, a small root launch daemon written in C, opens one BPF device read-only
on a request over XPC, binds it to the requested interface, returns the descriptor in the
reply, and keeps nothing. It answers only a sender that runs as the installing user,
carries Tattle's signature, and cannot be steered by another process of that user. The
checks, and how install verifies the build before root runs it, are in
[ADR-0003](adr/0003-bpf-descriptor-broker.md). Installing and removing it goes through the
standard macOS administrator password dialog. The Packet access screen shows the exact
plist first; the Startup tab's Remove does not. Everything else runs as the user: the socket table, the login-items database (with Full Disk Access),
signatures, and launch agents need no root on current macOS. There is no `sudo`.

## Storage

SQLite through GRDB: typed records and migrations. The tabs read in-memory `@Observable`
snapshots, not the database. Tables: `connection` (history), `rule` (the knowledge base),
`setting`.

## Third-party data and licenses

| Data | Source | License | Handling |
|---|---|---|---|
| IP block owner (later) | iptoasn.com | PDDL 1.0 | not built yet; to be bundled |
| Domain category and owner | DuckDuckGo Tracker Radar | CC BY-NC-SA 4.0 | separate file under its own license, shipped with no rules; the app runs without it; non-commercial forks only |
| MAC vendor (later) | IEEE OUI registry | no copyright asserted | bundled |
| Apple hosts | Apple, "Use Apple products on enterprise networks" (support.apple.com/101555) | Apple copyright | the seed file ships with no rules; facts to be transcribed into it, with the source URL and transcription date; partial and enterprise-oriented, re-checked each macOS release |
| App intent (later) | `InternetAccessPolicy.plist` in app bundles | app's own | not built yet; to be read from disk at runtime, only from validly signed bundles; rare (2 of 63 apps on the development machine) |

The app is MIT. The knowledge base is split-licensed by source file so the ShareAlike data
never contaminates the rest.

## Stack

Swift, SwiftUI `MenuBarExtra`, macOS 14 or later. Swift Package Manager with a Makefile target
(`make app`) that assembles the app bundle (Info.plist with `LSUIElement`) and signs it and the broker with
the hardened runtime: with the first Apple Development identity in the keychain, or ad hoc
without one; no Xcode project
unless something forces one. GitHub Actions on `macos-latest` runs the tests and `make app`
on every push.

The app icon is an eye, drawn in `Resources/AppIcon.svg`. `make icon` redraws
`Resources/AppIcon.icns` from it with `sips` and `iconutil`; the `.icns` is committed, so a
build does not depend on either. The menu bar item shows the same eye in one colour, drawn
in code (`MenuBarGlyph`) as a template image, and struck through when Tattle failed to start.
