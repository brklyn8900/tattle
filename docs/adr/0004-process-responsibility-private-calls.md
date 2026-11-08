---
title: "ADR-0004: Private libquarantine calls for process responsibility"
status: Accepted
date: 2026-11-08
---

# ADR-0004: Private libquarantine calls for process responsibility

**Status:** Accepted

## Context

macOS keeps a responsible process for every process, and the permission system (TCC)
charges a process's access to it. A child inherits its parent's. Tattle depends on this
in two places. Apple offers no public call for either; both calls are in
`/usr/lib/system/libquarantine.dylib` and in no SDK header.

**Reading it.** A service that launchd started for an app has launchd as its parent, so
neither the parent chain nor, for a service outside the bundle, the path says whose it
is. `responsibility_get_pid_responsible_for_pid` does. Processes and Network use it for a
process whose parent is launchd and that nothing else ties to an app.

**Giving it up.** Explain runs a command the user chose. Attributed to Tattle, that
command holds every grant Tattle has, Full Disk Access included (ADR-0002). A process of
the user's that lacks those grants can choose what the command is: `provider.command` is
a row in a user-writable database, the shell comes from `SHELL`, and the login shell reads
`~/.zprofile`. Its code would hold the grants on the next Explain. A fixed shell and
environment close the first two routes and leave the startup files; dropping the login
shell loses the PATH the user's CLI is found on.

## Decision

1. Tattle uses two private calls, `responsibility_get_pid_responsible_for_pid` and
   `responsibility_spawnattrs_setdisclaim`. Both are resolved with `dlsym` at run time, in
   `ResponsibleProcess.swift` and nowhere else.
2. Explain starts its command disclaimed, so macOS charges its access to it and not to
   Tattle, and suspended, so the read can confirm that before any of its code runs.
3. Explain runs a command only once that is confirmed, and otherwise refuses and says so:
   running it would hand over the grants without a word. If the disclaim is missing or
   reports an error, the command is never started. If the read is missing, or reports
   anything but the command itself, the suspended process is killed. For Processes and
   Network, a missing read means only that a service is not filed under its app; it is
   still listed.

## Consequences

- Any process of the user's can still change what Explain runs. That gains it none of
  Tattle's grants: the command holds no more than that process already does. It does read
  the prompt, and on a Startup row that includes the Developer and Team facts Tattle reads
  with Full Disk Access.
- A command that touches a protected folder gets what its own program would get: macOS
  decides for the shell or the tool, not from Tattle's grant.
- A private call can change without notice. Each start is checked, so a disclaim that stops
  having its effect refuses Explain on the user's Mac instead of handing over the grants, and
  `testTheCommandAnswersForItself` fails on it here.

## Alternatives

- Starting the command through launchd instead of as a child. Explain would lose the pipes
  and the process group it uses for the prompt, the answer and the timeout. Rejected.
