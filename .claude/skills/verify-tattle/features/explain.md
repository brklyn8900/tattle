# Explain

Every detail in the four tabs ends in an explanation section. When the knowledge base has
a rule for the item, the section shows it with its provenance (`Tattle's rules · risk low ·
confidence high`). Otherwise it reads `No explanation yet.` with an `Explain` button, which
sends one redacted prompt to the provider command configured in Settings and stores the
answer as an unconfirmed rule (`Model answer, unconfirmed · ...`), for the code it was
given for: another program under the same name does not get it, confirmed or not. With
nothing to tell that code by, such as unnamed code, the answer stays while the detail is
open and is not kept. Shipped rules about Apple's programs show only for Apple's own program
by that name: Apple-signed, on the sealed system volume, and named for its own file. A
shipped rule with another publisher's name on it shows only for that publisher's program.

## Sub-features

- `ex-rule`: a shipped or stored rule shown without asking.
- `ex-apple-gate`: an impostor named after one of Apple's programs gets no shipped rule.
- `ex-ask`: `Explain` runs the provider and shows its answer.
- `ex-identity`: an answer shows only for the code it was given for; another program by
  the name can be asked about, and keeps its own answer.
- `ex-unkept`: an answer about code nothing identifies shows with no `Confirm` and is not
  stored.
- `ex-publisher`: the shipped `claude` rule shows for Anthropic's program only.
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
      sqlite3 "$D" "insert into setting (key, value) values ('provider.command', '$PWD/.claude/skills/verify-tattle/scripts/fake-provider $PWD/build/verify/prompts') on conflict (key) do update set value = excluded.value"

  An `update` alone changes nothing when the copy never saved a provider, and `Explain`
  then stays disabled. After cleanup, write the saved value back with a parameter binding
  (it holds quotes), or delete the row if the saved file is empty, and delete the rules the
  run stored: `purpose = 'fake answer for the verify run'`.

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

- **An answer goes with its code.** With the fake provider, load a launch agent running
  `/bin/sh <dir>/a/updater` (`while :; do sleep 5; done`). In Processes, press `updater,`:
  `No explanation yet.`; press `Explain`, then `Confirm`: `Model answer, confirmed by you`.
  Replace the agent with `/bin/sh <dir>/b/updater` and open its row: `No explanation yet.`;
  `Explain` stores a second answer. Put `a` back: `Model answer, confirmed by you`. `$V db
  "select pattern, identity, confirmed is not null from rule where source = 'llm'"`: two
  rows, `script:<dir>/a/updater` confirmed and `script:<dir>/b/updater` not.
- **An answer nothing can keep.** A launch agent running `/bin/sh -c "while :; do sleep 5;
  done"`, row `sh,`: `Signed by unnamed code`, `No explanation yet.` `Explain` shows the
  answer with no `Confirm`, and it is still there after the tab refreshes; `$V db "select
  count(*) from rule where pattern = 'sh' and source = 'llm'"` is 0.
- **The shipped `claude` rule.** Where a real Claude Code session runs, open the row holding
  it (`Herdr Core,` here), then `--prefix "claude, pid <pid>"` (`claude, pid N · Anthropic
  PBC`): the detail ends in `Claude Code, Anthropic's coding agent ...` and `Tattle's rules ·
  risk low · confidence high`. A script under the name, `/bin/sh <dir>/claude` started from
  a terminal app (its member row is `claude, pid N · bash script`), has `Signed by script,
  not signed` and `No explanation yet.`

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
- Shipped rule proven again 2026-11-07 on testmac (macOS 26.7.1, where Apple's binaries are
  signed `macOS Software Signing`), dev copy at `879a2ca`, run `2026-11-07T180918`: the
  `5353, mDNSResponder` detail has `Signed by Apple` and the rule; again at `32a5508`, run
  `2026-11-07T195705`.
- An answer going with its code, and one nothing can keep, proven 2026-11-08 on testmac, dev
  copy at `ebf12ca`, run `2026-11-08T104732`, copied to `build/verify/runs/testmac-2026-11-08/`.
- The `claude` rule proven 2026-11-08 on the development Mac, where a real session runs,
  dev copy at `ebf12ca`: the script under the name in run `2026-11-08T104814`, Anthropic's
  program in run `2026-11-08T105317`.
