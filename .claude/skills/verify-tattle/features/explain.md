# Explain

Every detail in the four tabs ends in an explanation section. When the knowledge base has
a rule for the item, the section shows it with its provenance (`Tattle's rules · risk low ·
confidence high`). Otherwise it reads `No explanation yet.` with an `Explain` button, which
sends one redacted prompt to the provider command configured in Settings and stores the
answer as an unconfirmed rule (`Model answer, unconfirmed · ...`), for the code it was
given for: another program under the same name does not get it, confirmed or not. Code with
no publisher is known at one version: by its signature's own hash, or, for unsigned code and
scripts, by the file's content, read only when an answer is looked up or stored. A file that
cannot be read keeps no answer. A launch item whose line holds its code, or runs one of Apple's
installed programs, is known by the line; one whose line does not say where its code is keeps
none. With nothing to tell that code by, such as unnamed code, the
answer stays while the detail holds that code and is not kept. A host's prompt says nothing
of the program that connected. Shipped rules about Apple's programs show only for Apple's own program
by that name: Apple-signed, on the sealed system volume, and named for its own file. A
shipped rule with another publisher's name on it shows only for that publisher's program.
The provider command runs answering for itself, so it holds none of Tattle's privacy grants
(ADR-0004). The Claude Code preset keeps no transcript and starts none of the account's
connectors.

## Sub-features

- `ex-rule`: a shipped or stored rule shown without asking.
- `ex-apple-gate`: an impostor named after one of Apple's programs gets no shipped rule.
- `ex-ask`: `Explain` runs the provider and shows its answer.
- `ex-identity`: an answer shows only for the code it was given for; another program by
  the name can be asked about, and keeps its own answer.
- `ex-version`: an answer goes with one version of code that has no publisher: a script or
  unsigned file edited or replaced at its path, ad hoc code rebuilt there, even under its old
  modification date, and a launch item whose line or program changes.
- `ex-line`: a launch item's line alone says which code it is when it holds that code or runs
  one of Apple's installed programs; a line that does not say where its code is keeps no answer.
- `ex-unkept`: an answer about code nothing identifies, or whose file cannot be read, shows
  with no `Confirm` and is not stored; it goes when the row comes to hold other code.
- `ex-host`: a host's prompt carries the host and the connection, not who made it.
- `ex-publisher`: the shipped `claude` rule shows for Anthropic's program only.
- `ex-redaction`: the prompt carries the item and facts as one JSON line; the key and the
  facts share one redaction, set by what the item is. The default instructions go out as
  written, and edited ones lose the login, the Mac's names and addresses.
- `ex-no-grants`: the command is charged to itself, and cannot open what only Tattle's Full
  Disk Access opens.
- `ex-preset`: the Claude Code preset works from the app and leaves nothing per call. A
  command saved by an earlier version is moved to the current preset once; the same text
  typed later stays the user's.
- `ex-login-path`: Settings says the command must work from a login shell, which does not
  read `~/.zshrc`.

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
- **What the prompt keeps back.** With the fake provider, start processes under a title
  (`nohup zsh -c "exec -a '<title>' /bin/sleep 900" &` from a script in Ghostty; Processes,
  row `Ghostty,`, then the title) and add plists, not loaded, to `~/Library/LaunchAgents`
  (Startup, `Refresh`, the label). Press `Explain` on each and read the recorded prompt:
  - title `postgres: <login> <machine name> [local] idle`: the key and `Process` read
    `postgres: <user> <machine name> [local] idle`, the Mac's name left in a process; the login
    in capitals, `<LOGIN>-helper`, stays;
  - label `com.<login>.proof`: the key reads `com.<user>.proof` and `Plist`
    `<home>/Library/LaunchAgents/com.<user>.proof.plist`; label `com.<machine name>.proof` reads
    `com.<machine>.proof` in both;
  - a script `<dir>/com.<login>.tool.sh` run by `/bin/sh` (row `com.<login>.tool.sh`): the key
    and `Process` read `com.<user>.tool.sh`;
  - a plist running `/Users/someone/bin/tool`: `Runs` reads `/Users/<other-user>/bin/tool (1
    argument, not sent)`; one running `/opt/app/users/tool` is unchanged; one running
    `/Volumes/Proof Disk/bin/tool` with that disk mounted (`hdiutil create -size 2m -fs HFS+
    -volname "Proof Disk" <dmg>`, `hdiutil attach -nobrowse <dmg>`) reads
    `/Volumes/<volume>/bin/tool (1 argument, not sent)`;
  - `prompt.instructions` saved with the Mac's name and the login in it: the prompt's first
    line has `<machine>` and `<user>`. With no row, it is the default text as written. Restore
    or delete the row after the run;
  - where the login has one or two letters, the title `sshd-session: <login> <login>@ttys003`
    reads `sshd-session: <user> <user>@ttys003`;
  - where the computer name has a curly apostrophe, edited instructions spelling it with a
    straight one read `<machine>`.

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
- **One version of the code.** A launch agent running `/bin/sh <dir>/job.sh`. In Processes,
  `job.sh,`: `Explain`, `Confirm`. `$V db "select identity from rule where pattern =
  'job.sh'"` is `script:<dir>/job.sh:sha256:<hash>`. Append a line to the file and reopen the
  row: `No explanation yet.`; remove the line and reopen: `Model answer, confirmed by you`.
  With a program of your own in place of the script, ad hoc signed, the identity is
  `ad-hoc:<hash>:<path>`; unsigned (Intel only), `unsigned:<path>:sha256:<hash>`. Stop it,
  replace the file with another build, start it again: `No explanation yet.`
- **A file that cannot be read.** The same agent, then `chmod 000 <dir>/job2.sh`: `Explain`
  shows the answer with no `Confirm`, and no rule is stored.
- **A launch item through a wrapper.** A plist, not loaded, with `/usr/bin/env <dir>/good`.
  In Startup, press `Refresh`, then its row: `Explain`, `Confirm`; the identity is
  `command:<hash>:sha256:<hash>`. Change the plist to `<dir>/evil`, `Refresh`, reopen: `Runs`
  names it and `No explanation yet.`; change it back: confirmed again. Then replace the file
  `good` itself: `No explanation yet.`
- **A program replaced under its old date.** A plist, not loaded, running an ad hoc program of
  your own. In Startup, `Refresh`, its row: `Explain`, `Confirm`; the identity is
  `command:<hash>:<hash>`. Copy another ad hoc build beside it, `touch -r` the old file's date
  onto the copy, `mv` it over. `Refresh`, reopen: `No explanation yet.`; put the first build
  back the same way: confirmed again.
- **One of Apple's programs, by its line.** A plist, not loaded, running `/bin/sleep 86400`:
  `Explain`, `Confirm`; the identity is `command:<hash>` with nothing after it. With a copy of
  `/bin/sleep` in a folder of your own, `command:<hash>:<hash>`.
- **A line that does not say where its code is.** Plists, not loaded, running `/usr/bin/env -S
  <dir>/tool`, `/bin/sh` with `StandardInPath`, and `/usr/bin/python3 -m http.server`: `Explain`
  shows the answer with no `Confirm`, and no rule is stored. `/bin/sh -c "echo proof"` offers
  `Confirm`, and its identity is `command:<hash>`.
- **An answer that was not kept goes with its code.** A row shared by two programs of one
  name (Network, below in `network-names.md`): `Explain` shows the answer with no `Confirm`.
  Stop one of the two and end its connection: when the row holds one program the detail reads
  `No explanation yet.`
- **A host's prompt.** With the fake provider, open a connection's detail and `Explain`. The
  panel shows `Process`, `App` and `Signed by`; the recorded prompt's `facts` hold only
  `Destination`, `Protocol`, `Reach`, `Since` and `First contact`.
- **The shipped `claude` rule.** Where a real Claude Code session runs, open the row holding
  it (`Herdr Core,` here), then `--prefix "claude, pid <pid>"` (`claude, pid N · Anthropic
  PBC`): the detail ends in `Claude Code, Anthropic's coding agent ...` and `Tattle's rules ·
  risk low · confidence high`. A script under the name, `/bin/sh <dir>/claude` started from
  a terminal app (its member row is `claude, pid N · bash script`), has `Signed by script,
  not signed` and `No explanation yet.`
- **The command holds none of Tattle's grants.** On a copy with Full Disk Access (the dev copy
  on the development Mac; check that Startup lists `Allowed in the background` with no `Login
  items need Full Disk Access`). Point `provider.command` at a script that records
  `responsibility_get_pid_responsible_for_pid($$)` (a few lines of C through `dlsym`, as in
  `ResponsibleProcess.swift`; `launchctl procinfo` needs root) and the result of `ls
  /private/var/db/com.apple.backgroundtaskmanagement/`, then prints the fake answer. Press
  `Explain` on the `connect named` row: the record says the shell is charged to `/bin/zsh` and
  `ls` fails with `Operation not permitted`. A build before the fix: charged to the copy's
  `tattle`, `ls` lists the `.btm` files.
- **The Claude Code preset, for real.** One real request; the item goes to Anthropic, so use
  the `connect named` row. Migration `v6-claude-preset-flags` runs once per database, so before
  launch delete its row from `grdb_migrations` and save the earlier preset (`claude -p
  --setting-sources project,local --tools "" --permission-prompts none --output-format json
  --json-schema {schema}`) as `provider.command`. Count `~/.claude/projects/*tattle-explain*`,
  `~/Library/Caches/claude-cli-nodejs/*tattle-explain*` and `tattle-explain` in `~/.claude.json`.
  After launch the row holds the current preset. `Explain` gives `Model answer, unconfirmed`,
  and the three counts do not change. With the earlier preset's flags, a signed-in call adds a
  folder to each of the first two.
- **Settings.** `tattle-ax` reaches only the panel. Walk the app's `AXWindows` whose subrole
  is not `AXSystemDialog`, after `$V tab Network` and `$V ax press "Settings..."`. After the
  migration the `AXPopUpButton` reads `Claude Code` and the command field holds the current
  flags. Put the earlier preset's text in the row with the app quit, and relaunch: the row
  keeps it and the picker reads `Custom`. Setting the field's `AXValue` returns success but does
  not reach SwiftUI's binding, so the row is what to write. The footnote says `The command must
  work from a login shell`.

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
- Startup reads its items once; going back to the tab does not read them again. Press
  `Refresh` after changing a plist.
- A closed connection stays in its row as `closing` for about 30 s after its listener has
  gone (33 s measured), and the row counts it until then.
- A refused command cannot be driven in the app: both private calls work on every macOS here.
  `testARefusedCommandNeverRunsAndLeavesNoChild` covers the refusal on a suspended child.
- Over plain ssh, `claude` reads `Not logged in` on testmac (seen 2026-11-08; inferred: the login
  keychain is not open to that session). `hc exec --on testmac` and testmac's GUI session are
  signed in.
- To see what the CLI sends, set `ANTHROPIC_BASE_URL` to a local relay that writes the request
  body and never the headers (they hold the token). A relay that answers 400 sends nothing on.
- A file in Documents, Desktop or Downloads makes macOS ask (`"TattleDev" would like to access
  files in your Documents folder`) the first time an answer is stored or looked up for it,
  and the detail waits for the reply. Nothing is read just by opening a detail with no answer
  kept for that file. Seen 2026-11-08 on testmac, run `2026-11-08T123311`; `tccutil reset
  SystemPolicyDocumentsFolder <bundle id>` puts it back.
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
- One version of the code, a file that cannot be read and a host's prompt proven 2026-11-08 on
  testmac, dev copy at `969e6d3`, run `2026-11-08T122412`; a launch item through a wrapper in run
  `2026-11-08T122957`; an unkept answer going with its code in run `2026-11-08T123157`. All
  copied to `build/verify/runs/testmac-2026-11-08/`.
- A program replaced under its old date, one of Apple's programs by its line and a line that
  does not say where its code is proven 2026-11-08 on testmac, dev copy at `0749baf`, run
  `2026-11-08T141229`, copied to `build/verify/runs/testmac-2026-11-08/`.
- The command holding none of Tattle's grants and the `~/.zshrc` line in Settings proven
  2026-11-08 on the development Mac, where the dev copy has Full Disk Access: before the fix at
  `01de0ee`, run `2026-11-08T170503`; after it at `ab06f99`, run `2026-11-08T170728`.
- The Claude Code preset proven 2026-11-08 on testmac, dev copy at `ab06f99`: one real request
  in run `2026-11-08T170858`, Settings in run `2026-11-08T171037`, both copied to
  `build/verify/runs/testmac-2026-11-08/`. Packet capture is off there, so the row was the
  connection's address.
- The suspended start and the one-shot migration proven 2026-11-08 on the development Mac,
  signed dev copy at `c59806d`, on a database holding the earlier preset: the migrated row,
  Settings and one real request in run `2026-11-08T174405`; the same text staying after a
  relaunch in run `2026-11-08T174445`; the command charged to `/bin/zsh` and refused the
  protected folder, with Startup listing login items, in run `2026-11-08T174453`.
- What the prompt keeps back proven 2026-11-08 at `781f6a3`: a process's title and capitals, the
  login and the Mac's name as a label's author, a script named for its author, another account's
  folder, a mounted disk's name and edited instructions on testmac, run `2026-11-08T185357`; a
  `users/` folder inside a path and the default instructions in run `2026-11-08T185610`, both
  copied to `build/verify/runs/testmac-2026-11-08/`; a one-letter login and the apostrophe on the
  development Mac, the only one with either, run `2026-11-08T185833`. A host's whole-name rule, a
  tailnet name, an address spelled with hyphens and a public bound address rest on unit tests:
  `connect` reaches only its approved hosts, and neither Mac holds a public address.
- A script's facts name its interpreter, not its own path (`Runs with: bash (/bin/bash)`), so a
  folder name in a script's path cannot be read from a process's prompt: use a plist's `Runs`.
