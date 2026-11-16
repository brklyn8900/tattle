# Ports

The Ports tab lists what is listening, grouped by who can reach it: `Reachable from your
network`, `This Mac only` and `Ephemeral UDP`. A listener is read as Processes and Network
read a process, by the code it runs: a script reads as the script, not as its interpreter,
and an answer about it is kept against the script's file.

## Sub-features

- `po-row`: `<port>, <name>, <PROTO> · <binding> · <signer>`.
- `po-code`: a detail has `Runs with`, `Signed by script, not signed` and `Interpreter signed
  by` for a script, `Signed by unnamed code` for inline code or an interpreter of another
  account's whose arguments cannot be read, and `Path` and its signer for a program.
- `po-kept`: an answer about a script is stored with the script's file and content.
- `po-quit`: `Quit <name>` for the user's own listeners, `Runs as <account>, so Tattle cannot
  quit it` for others'. `Runs as` is the listener's process's account, not the socket's creator.

## How to get to it (user POV)

- Click the eye, choose `Ports`, choose a row.

## Driving it with tattle-verify

Preconditions:

- Open run; doctor all `ok`.
- For the kept answer, the fake provider (explain.md).

- **A script listening.** On the test Mac: `<dir>/server.py` binding `127.0.0.1:18180`, run with
  `/usr/bin/python3`. `$V tab Ports`; the row reads `18180, server.py, TCP · localhost only ·
  script, not signed`. Its detail has `Process server.py (pid N)`, `Runs with Python
  (<path>)`, `Signed by script, not signed`, `Interpreter signed by Apple, outside macOS`
  (the Command Line Tools' Python), and no `Path`.
- **Its answer is kept.** Press `Explain`, `$V ax wait "fake answer"`. `$V db "select kind,
  match, pattern, source, identity from rule where purpose='fake answer for the verify
  run'"`: `port | exact | server.py:tcp/18180 | llm | script:<dir>/server.py:sha256:<digest>`.
  Leave and open the row again: `Model answer, unconfirmed`, without asking. Afterwards delete
  the rule.
- **Another account's listener.** `5353, mDNSResponder`: `Runs as _mdnsresponder, so Tattle
  cannot quit it`.

## Gotchas

- Proven 2026-11-08 on the test Mac, run `2026-11-08T210232` (commit `a687b73`); copy in this Mac's
  `build/verify/runs/test-mac-2026-11-08/`. Inline code and an interpreter whose arguments cannot be read
  rest on the unit test (`testAListenerIsReadAsTheCodeItRuns`).
- The row of an Apple-signed file outside macOS, `· Apple, outside macOS`, and the
  `Interpreter signed by Apple, outside macOS` line above were not put on screen (2026-11-15,
  the test Mac, commit `7e9f4cb`): the run's listener on a high loopback port was not listed,
  and it opened none on all interfaces, which raises the Application Firewall's prompt. They
  rest on the unit test (`testPorts` in `ApplesProgramTests`).
- A listener whose file is not the code it runs, with no signer, was not seen in the app
  (2026-11-15, the test Mac); it rests on `testPortsShowNoSignerForAProcessItsFileDoesNotVouchFor`.
- A process running as another account than its socket's creator rests on the unit test
  (`testAListenerRunsAsItsProcessNotItsSocket`): a socket-activated agent's listener on the test Mac
  (run `2026-11-08T221748`) stayed owned by launchd, and making one any other way needs root.
