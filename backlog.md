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
