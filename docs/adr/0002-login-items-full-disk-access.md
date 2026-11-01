---
title: "ADR-0002: Login items need Full Disk Access"
status: Accepted
date: 2026-10-19
---

# ADR-0002: Login items need Full Disk Access

**Status:** Accepted

## Context

The [PRD](../PRD.md) (Startup) reads the login-items database at
`/private/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v*.btm` and calls it
world-readable. The file permissions are `0644`, but on macOS 26 the folder is gated by
the Full Disk Access privacy control: a process without the grant gets "you don't have
permission to view it" on listing it. The claim held from a terminal that already had the
grant and failed in the app.

The database is the only source for apps set to open at login, helpers registered through
SMAppService, Background App Refresh, and for the developer name, team and System
Settings toggle state of plist-based items. The plist folders and `launchctl` need no
grant.

## Decision

1. Tattle asks for Full Disk Access, once, from the Startup tab, with a button to the
   System Settings pane and the reason stated in the tab. No dialog at launch.
2. Without the grant the tab works from the plist folders and `launchctl` alone, and says
   what is missing. Nothing else in the app depends on the grant.
3. Builds are signed with a stable identity so the grant survives rebuilds (Makefile).

## Consequences

- The README and the first-run experience must explain the grant: it is broad, and
  Tattle's only outbound traffic remains the user's explicit explain request.
- Ad-hoc signed releases lose the grant on every update (PRD, Distribution). The
  Startup tab shows the notice again when that happens.

## Alternatives

- Not reading the database. Loses the "Open at login" list, which System Settings
  shows and users most often ask about. Rejected.
- Reading it through a privileged helper. The PRD rules out privileged helpers;
  Full Disk Access is a user grant, not a privilege escalation. Rejected.
- `sfltool dumpbtm`. Raises an administrator password dialog on every call. Rejected.
