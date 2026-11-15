---
title: "ADR-0005: Shipped rules are read from the app, not from the database"
status: Accepted
date: 2026-11-15
---

# ADR-0005: Shipped rules are read from the app, not from the database

**Status:** Accepted

## Context

The database is an unencrypted file in the user's Application Support folder, and every
process of the user can write it (ADR-0003 accepts that for the history, ADR-0004 for
`provider.command`). The rule table in it held every rule: the shipped ones, copied in
from the seed files whenever a file's content changed, and the model's answers. A detail
names where its rule came from by the row's `source`.

So a process of the user could write a row and have it read as Tattle's own. A `builtin`
row carrying that process's own code identity, which it can work out for its own file,
read "Tattle's rules, risk low" for it. A `user` row read "Your rule", though no screen
makes one. A host row with a relay category made a destination read "relayed". One
port-wide row answered for every listener, and a row for one of Apple's programs replaced
the shipped rule about it. The row stayed until the seed file next changed.

## Decision

1. The shipped rules are read from the seed files in the app bundle at every launch, into
   memory. No rule of a shipped source is read from the database.
2. The database's rule table holds the model's answers. Only rows with the source `llm` are
   read, and only for the exact item: a pattern in the database answers for nothing.
3. Only shipped rules say that a name is a relay or a cover name.

## Consequences

- **A model answer can still be planted.** A process of the user can write, change or
  delete an `llm` row, with a confirmation date or without, so a row it wrote can read
  "Model answer, confirmed by you". For a program the row needs that program's identity,
  so a process can do this for its own code and for any program whose identity it knows.
  A confirmed answer ranks above a shipped rule, so such a row also takes the place of
  Tattle's rule for the item, under the model's label. A row the app cannot read, or a
  damaged table, fails the database's lookup for its item: the detail then shows the
  shipped rule, if there is one, and no kept answer. What a name is on the Network tab
  does not depend on the database. The user's own confirmed answers are kept and read as
  before.
- **A shipped rule is as hard to change as the app.** The rules are files in the bundle's
  `Contents/Resources/knowledge`. Whether macOS refuses to start an app whose resource
  file was changed after its first launch is unverified; the executable does not hold the
  files' hashes.
- **No rule of the user's own.** No screen makes a `user` rule, and a `user` row in the
  database is not read. A rule editor needs a storage decision of its own, and so does
  promoting a model's proposed pattern at confirmation.

## Alternatives

- Keep every rule in the database and sign each row with a key in a keychain item whose
  access list names Tattle. It would close the planted model answer too. Rejected: an
  ad-hoc build is known to the keychain by its code hash, so each new build asks again
  (inferred, not run); on a Mac that holds the signing key any process can sign as the
  team and pass the access list (ADR-0003); a lost key or a refused prompt makes every
  kept answer and confirmation unreadable; and a deleted row, or the file put back as it
  was earlier, still goes unnoticed.
