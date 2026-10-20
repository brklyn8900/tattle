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
   ChmodBPF-style daemon: a small root launch daemon that, on request over a local
   socket, opens one BPF device read-only, binds it to the requested interface, passes
   the descriptor to the caller with `SCM_RIGHTS`, and keeps nothing. It is written in
   C, does no parsing, and holds no state between requests.
2. The broker answers only a caller whose code satisfies the requirement recorded at
   install time: the app's team when it is signed with an Apple identity, its code hash
   when it is ad-hoc signed. The caller is identified by the socket peer's audit token,
   never by pid alone. An ad-hoc build changes hash on every rebuild and must reinstall
   the broker; the README says so.
3. All parsing runs in the app as the user, exactly as it would have with readable
   devices. A parser fault is a user-level crash.
4. Installing and removing the broker goes through the administrator password dialog
   with the exact plist shown first, as the proposal already required for the daemon,
   and the app explains in plain words what the grant does before asking. The Startup
   tab lists the broker like any other daemon, and removal is one click in Tattle.
5. Without the broker the Network tab works from the socket table alone, shows
   addresses instead of names, and says why.

This supersedes the "no privileged helper" sentence of the proposal's Privileges
section for this one piece. Everything else there stands: no `sudo`, nothing else runs
as root.

## Consequences

- No process other than Tattle can obtain packets, by the devices or by the broker.
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

- ChmodBPF-style readable devices, as proposed. Same install cost, strictly more
  exposure. Rejected once caller verification turned out to be available for free.
- A root helper that captures and parses, handing names to the app. Puts the parsers in
  a root process for no gain over the broker; privilege could be dropped after the
  open, which is the broker with extra steps. Rejected.
- Paid account and Network Extension. Would replace the sniffer and the broker with
  one sandboxed extension and allow blocking, at 99 USD a year plus System Settings
  approvals. Ruled out by the proposal's non-goal; the one alternative that would make
  this ADR unnecessary if that non-goal is ever dropped.
