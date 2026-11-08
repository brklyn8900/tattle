---
title: "ADR-0003: Packet access through a descriptor broker"
status: Accepted
date: 2026-10-20
---

# ADR-0003: Packet access through a descriptor broker

**Status:** Accepted

## Context

The [design](../design.md) (Privileges) gives the sniffer its packets by making
`/dev/bpf*` readable to the user's group through a ChmodBPF-style launch daemon, and the
[PRD](../PRD.md) (Non-goals) rules out a privileged helper because "without a stable signing identity a root helper
cannot verify who is talking to it". Both statements were made against an ad-hoc signed
build.

Readable devices expose the network metadata of every process on the Mac, including
root's daemons, to every process running as the user, for as long as the grant stands.
The grant stands at every boot, whether Tattle runs or not. The data is hostnames,
addresses and DNS answers, since nearly all payloads are encrypted. A process already
running as the user can read far more elsewhere. Still, readable devices hand a new
capability to any such process, and that is the price of the Network tab's names, which
are the tab's core.

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
PRD's "no paid account" non-goal is what rules it out, not a technical limit.

## Decision

1. `/dev/bpf*` stays root-only. The BPF daemon installer of build order step 5 becomes a
   descriptor broker, not a ChmodBPF-style daemon. The broker is a small root launch
   daemon. On a request over XPC, it opens one BPF device read-only, binds it to the
   requested interface, returns the descriptor in the reply to that request, and keeps
   nothing. launchd holds its Mach service in the system domain, where only root can
   register a name. launchd starts the broker on the first request, and starts it again
   after it exits a minute idle. The broker is written in C, does no parsing, and holds no
   state between requests.
2. The broker answers a request only when three conditions hold for the process that sent
   it. It never judges the sender from a pid. It judges the sender's code from the
   request's own audit token (`SecCodeCreateWithXPCMessage`). The token names the sending
   process as it was when it sent, and after an exec it names no code at all. The broker
   checks the conditions before it acts on anything in the request, although libxpc
   decodes every message, from any account, before the broker sees it.
   - **The sender runs as the user who installed the broker.** The plist records that
     uid. The broker reads the sender's uid from the connection
     (`xpc_connection_get_euid`). That uid is fixed when the connection is made. The
     broker closes each connection after its first message, answered or not, so the
     connection's uid is the uid of the request it answers.
   - **The sender's code satisfies the requirement recorded at install time.** With an
     Apple identity, the requirement is the app's team plus its identifier or the dev
     copy's (the same identifier with `.dev` appended, which `make run` builds). Ad hoc,
     it is the build's code hash. The running code must still match its file.
   - **No other process of that user can steer the sender.** The kernel reports the
     sender valid, running under the hardened runtime, and not debugged. Its code carries
     no get-task-allow and no entitlement that re-enables dyld environment variables or
     unsigned libraries.

   The reply, and with it the descriptor, goes to the request's reply port, which belongs
   to the sender. A forked child inherits no XPC connection.

   The only lever left to whoever launched the caller is the task exception ports the
   caller inherits, and the broker cannot see them. A trap would hand the caller's task to
   those ports. So Tattle drops its own exception ports before every request, the crash
   port included. The corpse-notification port stays, because macOS's crash reports arrive
   through it. Whoever holds it receives the dead process: no descriptor and no way to run
   code in it, but all of its memory can be read, and that holds the last packets Tattle
   read and the names it had. A launcher that holds the port can choose that moment by
   killing Tattle. Crash reports are worth that.

   Every build of Tattle and of the broker, ad hoc included, is signed with the hardened
   runtime. An ad-hoc build changes its code hash on every rebuild, so it must install the
   broker again. The app says when the installed broker is not this build's.
3. All parsing runs in the app as the user, exactly as it would have with readable
   devices. A parser fault is a user-level crash.
4. Installing and removing the broker goes through the administrator password dialog,
   with the exact plist shown first, as the design already required for the daemon.
   Before asking, the app explains in plain words what the grant does. The Startup tab
   lists the broker like any other daemon, and removal is one click in Tattle. Tattle
   refuses to install from a build the broker would refuse.

   The script the dialog runs carries everything root needs in its own text: the plist,
   the installing uid, and the code hash of the running build. The app confirms that hash
   against the code the kernel loaded, not against the file on disk. The dialog's shell
   gets a fixed environment, not Tattle's.

   Root reads nothing that a process of the user can write without verifying it first.
   The script:
   1. Copies the app bundle into a directory only root can enter.
   2. Refuses the copy if it holds links or special files.
   3. Checks the copy against the code hash with `codesign --deep`.
   4. Checks the copy's broker against the code hash that the copy's sealed
      `CodeResources` records for it. With a team, `--deep` alone is not enough, because
      it checks nested code only against the requirement recorded beside it, and with a
      team that requirement names no hash.
   5. Stops the old broker and waits for it to exit.
   6. Replaces the broker's files: the helper from the copy, and the plist from the
      script's own text.

   A failed install removes what it put in place.
5. Without the broker the Network tab works from the socket table alone, shows
   addresses instead of names, and says why.

This supersedes the "no privileged helper" sentence of the design's Privileges
section for this one piece. Everything else there stands: no `sudo`, nothing else runs
as root.

## Consequences

- Through the broker, packets go only to a process that runs as the installing user,
  carries Tattle's signature, and cannot be steered by another process of that user.
  Other accounts on the Mac are refused. This guarantee claims nothing about:
  - root
  - software that makes `/dev/bpf*` readable, such as Wireshark's ChmodBPF
  - a launcher that makes Tattle trap before it first asks
  - an app replaced before the user first opened it, which is the user installing
    someone else's app
- What "Tattle's signature" means depends on how the build is signed. Ad hoc, it means
  this exact build. With an Apple identity, it means any binary the team signed with
  Tattle's identifier or the dev copy's, older builds included. So a process that can use
  the signing identity (a keychain "Always Allow" grant to codesign) can make one.
  Admitting the dev copy widens nothing, because whoever can sign as the team can already
  sign with Tattle's own identifier. It lets a dev copy capture beside a running release
  build.
- Install pins the exact running build, and through its seal the exact bundled broker, in
  both signing modes, so swapping the bundle or the broker inside it during the dialog,
  for an altered build or an older signed one, installs nothing.
- Install has root parse the user's bundle (`ditto`, `codesign --verify`) before the
  verdict. The alternative was running its broker unchecked.
- The broker must be installed again when its code or its plist changes, and for another
  account. The Packet access screen says which. A build the broker refuses, such as the
  test runner, cannot use it, so tests call it through a signed fixture, and run the
  broker as an agent in the user's own launchd domain, which takes the same XPC path
  without root.
- `SecCodeCreateWithXPCMessage` is public, but the SDK states no availability for it. It
  is checked on macOS 26 only. The broker links it strongly, so the broker would not start
  on a release without it.
- The broker does not use XPC's own peer requirements, for two reasons. A peer they refuse
  sees only an interrupted connection, which the app could not tell from a crashed broker.
  And their lightweight form cannot say "no get-task-allow".
- Tattle handles no exceptions of its own, so dropping its exception ports loses nothing
  but an inherited handler for resource-limit reports. Crash reports come through the
  corpse-notification port, which Tattle keeps as it inherited it. A launcher that put its
  own port there gets the dead process instead, and macOS writes no report.
- The sniffer code is the same as planned. It receives a descriptor instead of opening
  the file.
- The broker is a second signed artifact to build, install and update. It is small
  enough to review in full, which is the point.
- The Apple Development certificate expires yearly. A renewed one keeps the team, so the
  requirement holds across renewal.
- Blocking, and with it the paid account, remains a Future item (PRD, Network
  Extension) and would be its own ADR.

## Alternatives

- A local socket whose peer is checked through `LOCAL_PEERTOKEN`, as first built.
  Rejected: the token describes whatever program the connecting pid runs when the broker
  asks, not the process that wrote the request, so the identity it checks need not be
  the one that receives the descriptor. Re-reading it later does not help.
- ChmodBPF-style readable devices, as proposed. Same install cost, strictly more
  exposure. Rejected once caller verification turned out to be available for free.
- A root helper that captures and parses, handing names to the app. Puts the parsers in
  a root process for no gain over the broker. Privilege could be dropped after the
  open, which is the broker with extra steps. Rejected.
- Verify the bundled broker on its own: by team requirement in team mode, by a code hash
  read from the bundle ad hoc. Rejected: the team check accepts an older broker the same
  team signed, and the ad-hoc hash comes from the very file being checked.
- Write the broker's code hash into the app at build time. Rejected: the app's own seal
  already records it, and builds without the step could not install.
- Paid account and Network Extension. Would replace the sniffer and the broker with
  one sandboxed extension and allow blocking, at 99 USD a year plus System Settings
  approvals. Ruled out by the PRD's non-goal. It is the one alternative that would
  make this ADR unnecessary if that non-goal is ever dropped.
