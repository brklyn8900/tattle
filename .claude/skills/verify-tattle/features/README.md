# Tattle verification map

The maintained list of Tattle's user-facing features and how to prove each in the run's
copy (the dev copy unless the run was launched with `--release`). Read this index, then
the feature's file.

## Baseline preconditions

- Repo at `~/dev/tattle`; commands run from its root with
  `V=.claude/skills/verify-tattle/scripts/tattle-verify`.
- A run is open: `$V launch` (or `--fresh`) succeeded and `$V doctor` is all `ok`.
- The run's copy (Tattle Dev, `io.github.eladefrati.tattle.dev`, or the release build,
  `io.github.eladefrati.tattle`) was launched by this run.
- The packet-access broker is installed and serves the run's copy (doctor's capture line
  says `through the broker`) for anything about names; otherwise the Network journeys
  fail on that precondition.

## Driving conventions

- Start each recipe with `$V tab <Tab>`, which opens the panel and leaves any detail.
- Press by label (`$V ax press`, `--prefix` for rows); read with `$V ax text`; never
  click by position.
- Rows are `"<name>, <subtitle>, <count>"`; connection rows are
  `"<name>, [from DNS,] [new,] <address:port> · <PROTO> · <state> · <process>, <age>"`.
- Mutations (packet access, Load/Unload, Quit) follow SKILL.md's Stop and ask.

## Proof and skip reporting

- Panel proof: `$V save <name>` before and after the action.
- Data proof: `$V db` for history, `$V log` for the subsystem's lines.
- Cite the run folder `build/verify/runs/<run-id>/` and the `commands.txt` times.
- Report an unreached entry point with the command tried and the unmet precondition;
  never report it as verified through another path.

## Feature entry contract

Each file: an H1 and a paragraph on the user-visible behaviour, then `Sub-features`, `How
to get to it (user POV)`, `Driving it with tattle-verify` (starting with
`Preconditions:`), `Gotchas`.

## Features

- [Network names and unnamed reasons](./network-names.md): who each connection goes to, or
  why Tattle could not tell. Proven 2026-10-25.
- [Packet access](./packet-access.md): installing and removing the broker that gives the
  sniffer packets; the password step is the user's. Remove and Install proven 2026-10-25 on
  both copies, Remove from Startup and the refused callers on the release build.
- [Startup items](./startup.md): what starts at login and boot, grouped, with details.
  Proven 2026-10-25; a command line's signer 2026-11-07; Apple's developer tools and
  `open`'s long options 2026-11-08.
- [Processes](./processes.md): running apps and programs with their helpers, memory and
  CPU, and Quit. Proven 2026-10-25; the macOS row, a script started by launchd, standard
  input under launchd, Python (with the Command Line Tools, with Xcode, and a Tk window),
  Swift (its frontend and its tools) and a package by its folder 2026-11-07; a compile job,
  with the Command Line Tools and with Xcode, 2026-11-08.
- [Explain](./explain.md): the explanation at the end of every detail, the Apple gate on
  shipped rules, and what the prompt sends, through a local fake provider. Proven
  2026-10-27.
