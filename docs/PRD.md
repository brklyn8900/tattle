# Tattle design

Design document. Status: accepted 2026-10-18. Changes after acceptance go to
[ADRs](adr/), not to this file.

## Overview

Tattle is a macOS menu bar app that shows what the Mac is doing and explains it in plain
language. It watches network connections, processes, listening ports, and startup items,
and for each answers the same four questions: what is this, who vouches for it, why is it
probably here, and should I care. A later version adds devices on the local network.

It is an explainer, not a firewall and not a system monitor. Little Snitch blocks and, with
its Research Assistant, explains connections from an online database it owns. KnockKnock
lists persistent items and checks them against VirusTotal. Stats and iStat Menus graph
resource use. Tattle is none of these and overlaps with all of them. What it does that they
don't:

- **Offline first.** The app makes no network call of its own. No telemetry, no update
  check, no cloud lookup.
- **Open source.** The knowledge base is data files in the repo; anyone can read, correct,
  or extend them.
- **A pluggable explainer.** When the built-in knowledge runs out, an "explain" button sends
  one item to an LLM the user already has, through a command the user configured, and the
  answer is kept locally so the question is never asked twice.
- **What changed.** First contact with a destination, a new listening port, a new startup
  item: diffs across every surface, which is what a privacy-minded user is actually
  looking for.
- **One place.** The same engine and the same question on every surface, so the user
  installs one app instead of three.

## Goals

- Live view of every outbound connection, and history within the retention period,
  attributed to the process that made it, with the hostname the process asked for wherever
  that can be observed.
- Every process, listening port, and persistent startup item on the machine, each with its
  code signer and the app responsible for it.
- A shared explanation pipeline that resolves names deterministically first, from a
  knowledge base second, and from a user-chosen LLM last, on click only.
- "What's new" on every surface.
- Open source from the first commit: license, CI on a clean runner, and the user's data
  kept out of the repo.

## Non-goals

- Blocking of any kind in the first version. Per-app, per-connection control needs a
  Network Extension and a paid Apple Developer account; machine-wide host blocking through
  `pf` resolves names at rule load, goes stale, and does not survive a reboot. See
  "Future".
- Resource history: graphs, temperatures, fans. A live resources line is in scope; iStat's
  job is not.
- Notarized or App Store distribution.
- Any network call the app makes on its own.
- Malware detection. Tattle says what something is; it does not score it.
- A privileged helper process. Without a stable signing identity a root helper cannot
  verify who is talking to it, so any local process could drive it.

## Audience

One user on their own Mac: privacy-curious, comfortable reading a hostname, not interested in
maintaining firewall rules. Published on GitHub for people like that.

## Design

### One engine, one question

Every surface runs the same pipeline on a different source:

1. **Observe**: collect raw items from the system.
2. **Identify**: attach deterministic facts: process, responsible app, code signer, owner of
   the IP block, category, the app's own declared intent.
3. **Explain**: match the item against the knowledge base; if nothing matches and the user
   clicks, ask the LLM and keep the answer.

The menu bar icon shows live in/out throughput. Clicking opens a panel with a resources
line (CPU, memory, network in/out; GPU has no public per-process source on Apple Silicon,
so it is left out until one exists) and four tabs.

### Network

Observe:

- The socket table with owning pid, for all users, without root, from the same `sysctl`
  (`net.inet.tcp.pcblist_n`, `net.inet.udp.pcblist_n`) that `netstat -anv` reads.
- Per-process byte counts from NetworkStatistics, the private framework behind `nettop`.
  It works unentitled today because a kernel gate is off; the tab degrades to interface
  totals if that changes.
- A BPF sniffer that reads three things and nothing else: DNS replies on port 53, to build
  an IP-to-name map; the TLS ClientHello on TCP, for the Server Name Indication; and the
  QUIC Initial packet, which carries the same ClientHello under a key derivable from the
  packet itself.

What the sniffer cannot see, stated plainly in the UI: names hidden by Encrypted Client
Hello (default in Firefox with DNS over HTTPS, in Chrome when Secure DNS returns one), DNS
done over HTTPS by browsers rather than the system resolver, and Safari traffic routed
through iCloud Private Relay. Those flows show the IP's owner and are labelled "name
hidden" or "relayed". macOS daemons use the system resolver, so they stay visible. Browser
traffic shows every destination the browser contacted, with owner, category, and bytes,
but not which page caused it: a browser is one process, so a connection reads "Chrome to
doubleclick (Google, advertising)", not "Chrome, nytimes.com tab, to doubleclick".
Attributing to a page would need a browser extension; the UI says so rather than
pretending.

Identify: forward hostname, IP block owner (ASN data), country, domain category and owning
company (Tracker Radar), Apple's published host list for Apple services, and the app's own
`InternetAccessPolicy.plist` on the rare occasions it ships one. Plaintext connections are
flagged.

Views: live connections grouped by app, then by service (forty Akamai hosts for one app
collapse to "Apple CDN"; service grouping uses only built-in and user rules, never LLM
answers); history per app and per destination; first contact; what talked while the screen
was locked.

Actions: explain; reveal the app.

### Processes

Observe: `proc_listpids` and `proc_pidinfo`, parent pid, CPU time and memory for sorting.
This is what is running right now, which neither Ports nor Startup shows.

Identify: code signature via `SecCodeCopySigningInformation`: Apple, a Team ID with the
organization name read from the leaf certificate, or unsigned. Helpers are attributed to
their app by walking the parent chain and by path containment (`Slack Helper (GPU)` lives
inside `Slack.app`). macOS also tracks a "responsible process" for TCC, but the only call
that reads it is private; it is a fallback to consider if attribution gaps show up, not a
dependency. A built-in glossary covers macOS daemons: `nsurlsessiond`, `trustd`, `apsd`,
`mDNSResponder`, and the rest.

Actions: explain; quit or force-quit; reveal in Finder.

### Ports

Observe: listening TCP and UDP sockets with owning pid, from the same `sysctl` as Network.

Identify: process and signer; whether the socket is bound to loopback only or to all
interfaces, which is what decides "reachable from my LAN". Well-known port names.

Actions: explain; quit the owner.

### Startup

Observe: `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`, cron
and `periodic` entries, `launchctl` state for each, and the login-items database
(`/private/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v*.btm`), which is
world-readable, undocumented, and a keyed archive with more than one schema version in the
wild; KnockKnock has a parser to learn from. System items under `/System/Library` sit in a
collapsed "Apple" group.

Identify: program path and arguments, trigger (at login, on a schedule, on demand, watching
a path), loaded or not, last run, signer, and the installing app, matched by bundle
identifier prefix and signer.

System Settings shows two lists of developer names with toggles. This tab shows what each
item runs, when, and why. Control stays where it already works: plist-based items can be
loaded and unloaded here; database-backed login items are toggled in System Settings via a
deep link.

Actions: explain; load/unload; reveal the plist; open System Settings.

### Explanation pipeline

Resolution order for any item:

1. **Facts** the engine already has: signer, owner, category, declared intent. Shown
   regardless.
2. **Knowledge base**: one SQLite table of rules. A rule has a `kind` (host, process, port,
   launch item), a `match` that is either an exact item or a glob pattern
   (`p*-caldav.icloud.com`, `com.apple.*`), `owner`, `purpose`, `category`, `risk`,
   `confidence`, `source`, and `confirmed` (a timestamp, null until the user confirms).
   Sources in precedence order: `user`, `builtin`, `iap`, `apple-list`, `tracker-radar`,
   `llm`; a confirmed rule ranks with `user` whatever its source.
3. **LLM**, on click only. The request carries the item and every fact from step 1, so the
   model explains known facts instead of guessing. It returns structured JSON in the shape
   of a rule. The answer is stored as an **exact-item** rule with `source = llm`, shown as
   "unconfirmed" until the user has read it, judged it against the facts panel, and
   confirmed it. There is no automatic check; confirmation is the user's. The source stays
   `llm` so provenance is never lost. The model may propose a pattern, but only the user
   can promote a rule to one, at confirmation. Unconfirmed LLM rules expire after 45 days. LLM rules never drive service grouping. A model
   choosing `*.akamaiedge.net` as "Apple CDN" would otherwise mislabel every later match.

The seed knowledge base ships in the repo as JSON files, one per source, compiled into
SQLite at build time. Contributions are pull requests against those files. The user's local
rules and LLM answers live in `~/Library/Application Support/Tattle/` and never touch the
repo.

### LLM provider

A shell command template, nothing else. The prompt goes to stdin; the answer is read from
stdout. Presets for `claude -p`, `codex exec`, and `ollama run`, plus a custom field. This
covers hosted and local models with no SDK dependency, and the user pays with an account
they already have.

- `claude -p`: run with `--bare --tools "" --permission-prompts none --output-format json
  --json-schema <rule schema>`; the JSON envelope's `result` field holds the answer.
- `codex exec`: it is an agent with a sandbox, so it runs in an empty working directory.
- `ollama run <model>`: reads the prompt from stdin.

Before anything is sent, the request is redacted: private IP ranges, the user's home path
and username, and machine names are replaced with placeholders. The item being explained is
the only payload.

Settings shows:

- the provider command;
- the prompt instructions, editable, with reset to default;
- the output contract (the JSON schema), read-only, appended to every request, because
  editing it would silently break the knowledge base;
- the last prompt sent, verbatim, after redaction.

Nothing is sent until the user has chosen a provider and clicked explain on an item.

### Privileges

The only privileged piece is read access to `/dev/bpf*` for the sniffer. The devices are
recreated root-only at every boot, so a one-off `chmod` does not hold. Tattle uses the same
approach as Wireshark's ChmodBPF: a small launch daemon that, at boot, creates a group,
puts the user in it, and gives that group read/write on the BPF devices. Installing and
removing it goes through the standard macOS administrator password dialog, with the exact
plist shown first. Everything else runs as the user: the socket table, the login-items
database, signatures, and launch agents need no root on current macOS. There is no
privileged helper and no `sudo`.

### Privacy and retention

- Connection history is kept in the local database for a configurable period, 30 days by
  default, then pruned. The database is excluded from Spotlight. The user decides whether
  Time Machine backs it up; the default leaves it included.
- Nothing leaves the machine except an explicit, redacted LLM request.
- The app has no account, no identifier, no crash reporter.

### Storage

SQLite through GRDB: typed records, migrations, and value observation that pushes query
results to SwiftUI when rows change, which is what every tab needs. Tables: connections
(history), items seen per tab (for "new since"), knowledge base rules, settings.

### Third-party data and licenses

| Data | Source | License | Handling |
|---|---|---|---|
| IP block owner | iptoasn.com | PDDL 1.0 | bundled |
| Domain category and owner | DuckDuckGo Tracker Radar | CC BY-NC-SA 4.0 | separate file under its own license; the app runs without it; non-commercial forks only |
| MAC vendor (later) | IEEE OUI registry | no copyright asserted | bundled |
| Apple hosts | Apple, "Use Apple products on enterprise networks" (support.apple.com/101555) | Apple copyright | facts transcribed into the seed, with the source URL and transcription date; partial and enterprise-oriented, re-checked each macOS release |
| App intent | `InternetAccessPolicy.plist` in app bundles | app's own | read from disk at runtime, only from validly signed bundles; rare (2 of 63 apps on the development machine) |

The app is MIT. The knowledge base is split-licensed by source file so the ShareAlike data
never contaminates the rest.

### Distribution

Releases are ad-hoc signed. On current macOS a user opens one by allowing it under System
Settings, Privacy & Security, after the first blocked launch; the README says so. Ad-hoc
signatures do not carry a stable identity, so TCC permissions are asked again after every
new build. Each release publishes a checksum. Building from source is a first-class path.
A Homebrew cask is possible; the user passes `--no-quarantine` themselves.

### Stack

Swift, SwiftUI `MenuBarExtra`, macOS 14 or later. Swift Package Manager with a script that
assembles the app bundle (Info.plist with `LSUIElement`, `codesign -s -`); no Xcode project
unless something forces one. GitHub Actions on `macos-latest` runs `swift build` and tests
on every push from the first commit.

## Build order

0. **Sniffer spike.** DNS, TCP SNI, QUIC Initial parsing, run for a day on the development
   machine, measuring what share of connections get a forward name. The Network tab's
   value depends on this number, so it is measured before anything is built on it.
1. Menu bar shell with throughput and the resources line; settings; knowledge-base table;
   LLM provider with redaction.
2. Startup tab. Small, static data, obscure names: the right place to prove the explanation
   pipeline before pointing it at a firehose.
3. Ports tab.
4. Processes tab.
5. Network tab: socket table and history first, then the sniffer from the spike, then
   the BPF daemon installer.

## Future

- **LAN tab.** Devices on the local network: ARP sweep and cache, Bonjour browsing, MAC
  vendor, open ports, new and gone since last scan. Same engine, same question. Runs only
  on request, never in the background, and triggers the macOS Local Network permission
  prompt. Apple devices randomize their Wi-Fi MAC addresses, so the Bonjour name does the
  identifying.
- **Network Extension.** A content-filter system extension would give exact per-flow
  attribution and make per-app allow/block possible. It would not give hostnames: the
  extension's `remoteHostname` is populated only for flows opened through URLSession or
  the Network framework, so browsers and Electron apps still need the DNS map. It needs a
  paid Apple Developer account, Developer ID signing, notarization, and user approval in
  System Settings. The observe layer is the only part that changes.
- **Per-page browser attribution.** The OS knows only that the browser opened a socket;
  which tab caused it is known inside the browser alone. A browser extension using the
  `webRequest` API would report each request's host and tab URL to Tattle over native
  messaging, and Tattle would join that with the socket it saw at the same moment to the
  same host. One extension per browser; Safari's needs Xcode and ideally a developer
  account.
- **Blocking**, if ever, as a decision of its own: `/etc/hosts` for names, the extension
  for apps.
- **Resource history**, if wanted, as a decision of its own.
- Shared knowledge-base contributions: export confirmed local rules as a pull request.

## Open questions

None at the time of writing.
