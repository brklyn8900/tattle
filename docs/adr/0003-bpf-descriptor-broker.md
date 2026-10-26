---
title: "ADR-0003: Packet access through a descriptor broker"
status: Accepted
date: 2026-10-20
---

# ADR-0003: Packet access through a descriptor broker

**Status:** Accepted

## Context

The [proposal](../proposal.md) (Privileges) gives the sniffer its packets by making
`/dev/bpf*` readable to the user's group through a ChmodBPF-style launch daemon, and
rules out a privileged helper because "without a stable signing identity a root helper
cannot verify who is talking to it". Both statements were made against an ad-hoc signed
build.

Readable devices expose the network metadata of every process on the Mac, including
root's daemons, to every process running as the user, for as long as the grant stands;
and it stands at every boot, Tattle running or not. The data is hostnames, addresses and
DNS answers, since nearly all payloads are encrypted; a process already running as the
user can read far more elsewhere. It is still a new capability handed to any such process,
and it is the price of the Network tab's names, which are its core.

Since ADR-0002 the build is signed with a free Apple Development identity, which carries
a team identifier. Checked on 2026-10-20: `codesign --verify` accepts the requirement
`anchor apple generic and certificate leaf[subject.OU] = "<team>"` on the built app and
rejects a wrong team. A root process can therefore verify that its caller is Tattle
without a paid account. Ad-hoc signed builds have no team but do have a code hash that
a requirement can pin.

A paid account would add the Network Extension. A content filter sees every socket
flow in the kernel, browsers and Electron apps included, with the owning process
attributed for free, and can ask for the first outbound bytes of each flow, which are
the TLS ClientHello on TCP and the QUIC Initial on UDP: the same bytes the sniffer
parses. It would replace the sniffer and the broker both, and allow blocking. The
proposal's "no paid account" non-goal is what rules it out, not a technical limit.

## Decision

1. `/dev/bpf*` stays root-only. Build order step 5c is a descriptor broker, not a
   ChmodBPF-style daemon: a small root launch daemon that, on request over XPC, opens one
   BPF device read-only, binds it to the requested interface, returns the descriptor in
   the reply to that request, and keeps nothing. launchd holds its Mach service in the
   system domain, where only root can register a name, starts it on the first request,
   and starts it again after it exits a minute idle. It is written in C, does no parsing,
   and holds no state between requests.
2. The broker answers a request only when three things hold of the process that sent it,
   never judged from a pid, and checked before it acts on anything in the request (libxpc
   decodes every message, any account's, before the broker sees it). Its code is judged
   from that request's own audit token (`SecCodeCreateWithXPCMessage`), which names the
   sending process as it was when it sent: after an exec it names no code at all. Its uid
   is the connection's (`xpc_connection_get_euid`), fixed when the connection is made; the
   broker closes each connection after its first message, answered or not, so that is the
   uid of the request it answers. The reply, and with it the descriptor,
   goes to that request's reply port, which belongs to its sender; a forked child inherits
   no XPC connection. The caller runs as the user who installed the broker, whose uid is
   recorded in the plist. Its code satisfies the requirement recorded at install time: the app's
   team and its identifier or the dev copy's (the same identifier with `.dev` appended,
   which `make run` builds) when it is signed with an Apple identity, its code hash when
   it is ad-hoc signed; the running code must still match its file. And no other process
   of that user can steer it: the kernel reports it valid, under the hardened runtime and
   not debugged, and it carries no get-task-allow and no entitlement that re-enables dyld
   environment variables or unsigned libraries. The broker cannot see the one lever left to
   whoever launched the caller, the task exception ports it inherits, to which a trap
   would hand the caller's task; so Tattle drops its own before every request. Every
   build of Tattle and of the broker, ad hoc included, is signed with the hardened
   runtime. An ad-hoc build changes hash on every rebuild and must reinstall the broker;
   the app says when the installed broker is not this build's.
3. All parsing runs in the app as the user, exactly as it would have with readable
   devices. A parser fault is a user-level crash.
4. Installing and removing the broker goes through the administrator password dialog
   with the exact plist shown first, as the proposal already required for the daemon,
   and the app explains in plain words what the grant does before asking. The Startup
   tab lists the broker like any other daemon, and removal is one click in Tattle.
   The script the dialog runs carries everything root needs in its own text: the plist,
   the installing uid, and the code hash of the running build, which the app confirms
   against the code the kernel loaded rather than the file on disk. Root reads nothing a
   process of the user can write without verifying it first: it copies the app bundle
   into a directory only root can enter, refuses a copy holding links or special files,
   checks the copy against that code hash with `codesign --deep`, checks the copy's broker
   against the code hash the copy's sealed `CodeResources` records for it (`--deep` checks
   nested code only against the requirement recorded beside it, which with a team names
   no hash), and installs the broker from the copy. It stops the old broker and
   waits for it to exit before replacing its files, and a failed install removes what it
   put in place. The dialog's shell gets a fixed environment, not Tattle's. Tattle
   refuses to install from a build the broker would refuse.
5. Without the broker the Network tab works from the socket table alone, shows
   addresses instead of names, and says why.

This supersedes the "no privileged helper" sentence of the proposal's Privileges
section for this one piece. Everything else there stands: no `sudo`, nothing else runs
as root.

## Consequences

- Through the broker, packets go only to a process that runs as the installing user,
  carries Tattle's signature, and cannot be steered by another process of that user. With
  an Apple identity, "Tattle's signature" means any binary the team signed with Tattle's
  identifier or the dev copy's, older builds included, so a process that can use the
  signing identity (a keychain "Always Allow" grant to codesign) can make one. Admitting
  the dev copy widens nothing: whoever can sign as the team can already sign with
  Tattle's own identifier. It lets a dev copy capture beside a running release build. Ad hoc, it means this exact
  build. Other accounts on the Mac are refused. Not claimed: anything about root, or about
  software that makes `/dev/bpf*` readable (Wireshark's ChmodBPF, for one), about a launcher
  that makes Tattle trap before it first asks, or about an app
  replaced before the user first opened it, which is the user installing someone else's
  app.
- Install pins the exact running build, and through its seal the exact bundled broker, in
  both signing modes, so swapping the bundle or the broker inside it during the dialog,
  for an altered build or an older signed one, installs nothing.
- Install has root parse the user's bundle (`ditto`, `codesign --verify`) before the
  verdict; the alternative was running its broker unchecked.
- The broker must be installed again when its code or its plist changes, and for another
  account; the Packet access screen says which. A build the broker refuses, such as the
  test runner, cannot use it, so tests call it through a signed fixture, and run the
  broker as an agent in the user's own launchd domain, which takes the same XPC path
  without root.
- `SecCodeCreateWithXPCMessage` is public, but the SDK states no availability for it; it
  is checked on macOS 26 only, and the broker links it strongly, so on a release without
  it the broker would not start. The broker does not use XPC's
  own peer requirements: a peer they refuse sees only an interrupted connection, which the
  app could not tell from a crashed broker, and their lightweight form cannot say "no
  get-task-allow".
- Tattle handles no exceptions of its own, so dropping its exception ports loses nothing
  but an inherited handler for resource-limit reports; crash reports still come through
  the system's own port.
- The sniffer code is the same as planned; it receives a descriptor instead of opening
  the file. Until the broker exists, testing uses a one-off `chmod o+r /dev/bpf*`
  reverted with `chmod o-r` afterwards; neither survives a reboot.
- The broker is a second signed artifact to build, install and update. It is small
  enough to review in full, which is the point.
- The Apple Development certificate expires yearly; a renewed one keeps the team, so the
  requirement holds across renewal.
- Blocking, and with it the paid account, remains a Future item (proposal, Network
  Extension) and would be its own ADR.

## Alternatives

- A local socket whose peer is checked through `LOCAL_PEERTOKEN`, as first built.
  Rejected: the token describes whatever program the connecting pid runs when the broker
  asks, not the process that wrote the request, so the identity it checks need not be
  the one that receives the descriptor. Re-reading it later does not help.
- ChmodBPF-style readable devices, as proposed. Same install cost, strictly more
  exposure. Rejected once caller verification turned out to be available for free.
- A root helper that captures and parses, handing names to the app. Puts the parsers in
  a root process for no gain over the broker; privilege could be dropped after the
  open, which is the broker with extra steps. Rejected.
- Verify the bundled broker on its own: by team requirement in team mode, by a code hash
  read from the bundle ad hoc. Rejected: the team check accepts an older broker the same
  team signed, and the ad-hoc hash comes from the very file being checked.
- Write the broker's code hash into the app at build time. Rejected: the app's own seal
  already records it, and builds without the step could not install.
- Paid account and Network Extension. Would replace the sniffer and the broker with
  one sandboxed extension and allow blocking, at 99 USD a year plus System Settings
  approvals. Ruled out by the proposal's non-goal; the one alternative that would make
  this ADR unnecessary if that non-goal is ever dropped.
