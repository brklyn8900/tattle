# Explain

Every detail in the four tabs ends in an explanation section. When the knowledge base has
a rule for the item, the section shows it with its provenance (`Tattle's rules · risk low ·
confidence high`). Otherwise it reads `No explanation yet.` with an `Explain` button, which
sends one redacted prompt to the provider command configured in Settings and stores the
answer as an unconfirmed rule (`Model answer, unconfirmed · ...`). Shipped rules about
Apple's programs show only for Apple's own program by that name: Apple-signed, on the
sealed system volume, and named for its own file.

## Sub-features

- `ex-rule`: a shipped or stored rule shown without asking.
- `ex-apple-gate`: an impostor named after one of Apple's programs gets no shipped rule.
- `ex-ask`: `Explain` runs the provider and shows its answer.
- `ex-redaction`: the prompt carries the item and facts as one JSON line; the key keeps
  only address redaction (`<private-ip>`), facts and instructions get the full redaction.

## How to get to it (user POV)

- Click the eye, choose a tab, choose a row; the explanation is at the end of the detail.

## Driving it with tattle-verify

Preconditions:

- Open run; doctor all `ok`.
- For `ex-ask` and `ex-redaction`, the run's copy uses the fake provider, so no prompt
  leaves the Mac. Before launch, save the copy's `provider.command` setting and point it
  at `scripts/fake-provider` with a folder in the run directory:

      D="$HOME/Library/Application Support/Tattle/tattle.sqlite"   # Tattle Dev/ for the dev copy
      sqlite3 "$D" "select value from setting where key='provider.command'" > provider-command-before.txt
      sqlite3 "$D" "update setting set value='$PWD/.claude/skills/verify-tattle/scripts/fake-provider $PWD/build/verify/prompts' where key='provider.command'"

  After cleanup, write the saved value back with a parameter binding (it holds quotes),
  and delete the rules the run stored: `purpose = 'fake answer for the verify run'`.

- **Shipped rule.** `$V tab Ports`, `$V ax press --prefix "5353, mDNSResponder"`: the
  detail ends in `The macOS name resolver: ...` and `Tattle's rules · risk low · confidence
  high`.
- **Apple gate.** Start impostors the run owns, then open each detail; each reads `No
  explanation yet.`:
  - a listener of your own built as `mDNSResponder` (Ports, row `<port>, mDNSResponder`);
  - `nohup zsh -c 'exec -a mDNSResponder /bin/sleep 900' &`, Apple-signed `/bin/sleep`
    under the name (Processes, filed under iTerm, about 20 scroll pages down).
  The real `mDNSResponder` (pid of `/usr/sbin/mDNSResponder`, under `macOS`) still shows
  the shipped rule.
- **Ask and redaction.** Open a connection to a private address the run owns: a Python
  listener bound to this Mac's own en0 address and a client connecting to it. The row
  shows under iTerm, `this network`. Press the row, `Explain`, `$V ax wait "fake answer"`.
  The recorded prompt's data line has `"item":{"key":"<private-ip>","kind":"host"}` and
  no address; the detail reads `Model answer, unconfirmed`.

## Gotchas

- Run each journey in one Bash call, from `$V tab` to the last read. The panel closes
  when anything else takes focus, and between calls it often has.
- A connection to this Mac's own LAN address is closed after about a minute (seen
  2026-10-27, cause unknown): open it in the same call that presses `Explain`.
- Copies of `/bin/sleep` and `/usr/bin/nc` are killed at launch (exit 137); build your own
  listener for the Ports impostor.
- A Network row shared by the real daemon and an impostor (a group merged by name) needs
  the real `mDNSResponder` to hold a connection at the same time. Its connections last 1
  to 2 s, and a 9-minute wait on 2026-10-27 never caught one: that case rests on the
  unit test.
- Proven 2026-10-27, run `2026-10-27T105938` (release build): shipped rule, Apple gate,
  ask and redaction.
