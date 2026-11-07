# Backlog

- Notifications for what's new: an opt-in macOS notification on first contact with a
  destination, a new listening port, or a new startup item. Needs a PRD change. After the
  search bar (agreed 2026-11-07).

**Backlog** (letters from the reflect review of 2026-10-22, cited in commit messages; (a) is
done)

- (b) A `make test` wall-clock limit with cleanup of what a killed run leaves behind. Each
  launched process already waits at most 60 s. Yes/no when raised.
- (c) Agreed (2026-10-26): on testmac, run the packet-access checks not yet proven (second
  account against the installed daemon, Cancel, Install for this account), then remove
  "to run on testmac" from `features/packet-access.md`.
- (d) `ResponsibleProcess` resolves a private libquarantine symbol by dlsym in an app whose
  rule is Apple frameworks only: decide whether that needs an ADR.
- (e) After Remove, the Startup tab keeps the broker's "Allowed in the background" row until
  Refresh: its refresh runs before macOS rewrites the background-items file, about a minute
  later.
- Check whether `StartupSnapshot`'s fallback to BTM's own `teamIdentifier` (when the
  signature has none) brings back an ad-hoc item's claimed team; where BTM gets that field
  is unverified (agreed 2026-10-27).

**From the review triage of 2026-11-07** (its "consider" list, verified at `0618f7e`; IDs
are the triage's)

- A4: A signer comes from the file at the process's path now, so a running program that
  renames an Apple binary over its own path reads as Apple. Only `SecCodeCheckValidity` on
  the running code catches it; its cost per process is unmeasured (`CodeSignature.swift`).
- E7g: A personal Apple Development team identifier is sent to the model, twice for a
  development signer (the "Signed by" summary and the Team facts).
- K6: A DNS-only name is unmarked in the Network detail headline, against ADR-0001
  decision 2, and becomes the Explain key (`NetworkTab.swift`, `NetworkSnapshot.swift`).
- E16: Retention is checked only in the UI; a stored 0 or negative value deletes every
  history row, open connections included (`AppSettings.swift`, `ConnectionStore.swift`).
- E14: Choosing Custom in the provider picker does nothing and snaps back, though the README
  says to pick it (`SettingsView.swift`).
- E4: Back and reopen during an Explain starts a second paid call; Quit leaves the provider
  and its temporary folder behind (`ExplainSection.swift`, `Provider.swift`).
- B6: The broker cancels the connection right after sending its reply, and the SDK says
  cancel discards unsent messages; a send barrier makes the order explicit
  (`tattle-capture-broker/main.c`).
- K9: A database error in the explain lookup reads as "No explanation yet"
  (`ExplainSection.swift`).
- K2: A process's own TLS server name can make its row read "relayed" or "name hidden"
  (`NetworkObserver.swift`).
- N25: A LAN peer that forges this Mac's MAC address can relabel a live UDP row; the kernel's
  direction flag (`BIOCSEXTHDR`) would stop it. Suspected, not run.
- S6: Two startup items with one label or bundle identifier share one detail view and one
  explain key (`StartupSnapshot.swift`, `StartupTab.swift`).
- S3: Login items from every account on the Mac are merged, and the first account's toggle
  wins (`LoginItems.swift`).
- S4: Apps that open at login never read "running": launchd labels them
  `application.<bundle id>.<n>.<n>` (`StartupSnapshot.swift`).
- S5: Calendar triggers read a missing key as 0, where launchd reads it as a wildcard
  (`LaunchdItem.swift`).
- P1: A port's process is the socket's last user, so socket-activated listeners show as
  launchd and an exited binder's pid can be shown (`SocketTable.swift`).
- B9: The Network header says Tattle lacks packet access while the broker is installed and
  capture fails for another reason (`PacketAccessView.swift`).
- B8: The friendly "cancelled" text for the administrator dialog is never shown, because
  osascript always writes to stderr (`CaptureBrokerInstall.swift`).
- E11: Confirm stays enabled during Ask again, and confirming then shows a raw
  `alreadyConfirmed` error (`ExplainSection.swift`).
- N8: One failed history write drops the rest of that poll's history
  (`NetworkObserver.swift`).
- N13: A failed filter rebuild keeps the old kernel filter, records the new direction, and
  logs "copying every packet" (`Sniffer.swift`).
- PR6: `ps` and `launchctl` run without a timeout; a hang would freeze the tab
  (`ProcessTable.swift`, `Launchctl.swift`).
