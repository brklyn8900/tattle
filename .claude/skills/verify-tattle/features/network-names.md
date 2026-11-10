# Network names and unnamed reasons

The Network tab lists open connections grouped by app. With packet access, each
connection to the internet gets the name it went to, from its TLS or QUIC handshake, its
HTTP request, or a DNS reply. When none of those work, the connection's detail says why
there is no name. History keeps the outcome: `name` and `nameSource` (`sni`, `quic`,
`http`, `dns`), or no name and `nameSource` `none:<reason>`.

## Sub-features

- `net-header`: heading `N open connections from M apps` and a sentence with new, already
  open, and `K named` / `from DNS` / `relayed` / `with the name hidden` counts. `named`
  counts names from the connection's own packets; DNS names are counted apart.
- `net-dns`: a name that came only from a DNS reply carries a grey `from DNS` tag after it
  in the row, and the detail says `Name from a DNS reply for the address`.
- `net-group`: a group row per app, opening a detail with facts and its connections.
- `net-named`: a connection detail with `Destination`, `Address`, and `Name from` (for
  example `the HTTP request`).
- `net-unnamed`: a connection detail with `No name` and the reason: `the connection did
  not start with a TLS or HTTP handshake`, `the connection sent nothing in its first 20
  seconds`, `part of the handshake was missed`, `the handshake carried no server name`,
  `the QUIC handshake could not be read`, `a QUIC version Tattle cannot read`.
- `net-signers`: a connection's detail names who signed the process that made it (`Signed
  by`), and the app it is filed under apart when that differs (`App signed by`, `App team`).
  A script reads `Signed by script, not signed`, with `Runs with` and `Interpreter signed
  by`; one of Apple's developer tools reads `Signed by unnamed code`. History keeps both, in
  `signer` and `appSigner`. A row whose connections have different signers names none. A
  process that replaces itself with another program is read again for its next connections,
  even when that program then deletes its file.
- `net-foreign`: a file in an app's bundle that the app's signer did not sign keeps the row
  from holding any answer given for the app; what the app only launches does not.
- `net-direction`: a connection states a direction on the first of these that holds. Outbound:
  this Mac's SYN or QUIC Initial was seen leaving, which needs packet access and a destination
  the sniffer follows; the detail is headed `<app> to <name>`, with `Destination` and `First
  contact`. Inbound: the socket sits on a listener's endpoint of its own family; a grey
  `incoming` tag, `<app> from <peer>`, `From` and `To port`. Outbound again: a local port of
  49152 or above, macOS's ephemeral range, which needs no packet access. Otherwise neither is
  claimed: `<app> with <peer>`, `Peer` and `Local port`, no `new`, no `First contact`, and the
  address does not count as reached. A group row says `N to`, `N from` or `N with the
  internet`. The model is told none of `Destination`, `First contact`, `From`, `To port`,
  `Peer` and `Local port`, since its answer is kept for the host. History keeps it in
  `direction`.
- `net-reach`: `Reach` reads `this network` for private, link-local and shared (100.64/10,
  Tailscale's) addresses.
- `net-history`: the same outcome in the `connection` table, written even when the
  connection closed before the outcome arrived.
- `net-names-off`: without packet access, the header says `Destinations are addresses:
  names need packet access, which Tattle does not have yet`.

## How to get to it (user POV)

- Click the eye in the menu bar; the panel opens on the Network tab.
- Choose an app's row, then a connection row.

## Driving it with tattle-verify

Preconditions:

- Open run; doctor all `ok`, capture `through the broker`.
- example.com reachable on port 80 and github.com on port 22.

- **Known connections.** Run `$V connect named`, `$V connect garbage`, `$V connect
  silent`, each printing its local port. Wait 25 s so the silent one passes the 20 s
  timeout.
- **List.** Run `$V tab Network` and `$V save network-list`. The heading reads `N open
  connections from M apps`; the sentence includes `K named`; an `iTerm, ...` row is there
  (the `nc` connections file under the terminal that started them).
- **Group.** Run `$V ax press --prefix "iTerm,"` and `$V ax text`. Connection rows read
  `example.com, new, <ip>:80 · TCP · connected · nc, ...` for the named one and
  `<github ip>:22, new, TCP · connected · nc, ...` for the other two. Use `$V ax scroll
  down` if they are below the fold.
- **Named.** Press `--prefix "example.com, "`, `$V ax wait "Name from"`, `$V save
  named-detail`. Facts: `Destination example.com`, `Name from the HTTP request`, `Process
  nc (pid <pid>)`, `App iTerm`.
- **Unnamed, not a handshake.** `Back`, press `--prefix "<github ip>:22, "`, check the
  `Process nc (pid ...)` fact against the garbage pid (else `Back` and open the other
  row with `$V ax dump` to find it), `$V save garbage-detail`. Facts: `No name
  the connection did not start with a TLS or HTTP handshake`.
- **Unnamed, timeout.** The same for the silent connection, `$V save silent-detail`. Facts:
  `No name the connection sent nothing in its first 20 seconds`.
- **History.** `$V db "select localPort, pid, processName, remoteAddress, remotePort,
  name, nameSource from connection where localPort in (<three ports>)"`: `example.com |
  http`, `| none:not-handshake`, `| none:timeout`.
- **Log.** `$V log "<port1>|<port2>|<port3>"`: `no name for tcp/<port>><ip>:80:
  notHandshake` and `...: timeout` lines.

- **A connection's own signer.** Every connection here goes to the Mac's own LAN address,
  so nothing leaves it and no packet access is needed. With `IP=$(ipconfig getifaddr en0)`,
  run from a script in a terminal app (Ghostty here): a listener on each of three ports,
  `sleep 317 | nc -l $IP <port> > /dev/null &`, then:
  - `sleep 317 | nc $IP 18081 > /dev/null &`. Detail: `Process nc`, `App Ghostty`, `Signed
    by Apple`, `App signed by Mitchell Hashimoto`, `App team 24VZTF6M5V`.
  - A renamed copy of Apple's interpreter: `cp <tools>/usr/bin/swift-frontend
    <dir>/bin/updater`, `ln -s <tools>/usr/lib <dir>/lib`, then `<dir>/bin/updater -frontend
    -sdk <sdk> <dir>/job.swift -interpret &`, where `<tools>` is
    `/Library/Developer/CommandLineTools` and `job.swift` connects to `$IP:18082` and sleeps;
    allow 30 s to compile. Detail: `Process job.swift`, `Runs with updater
    (<dir>/bin/updater)`, `Signed by script, not signed`, `Interpreter signed by Apple`,
    `Interpreter team 59GAB85EFG`, and the terminal's `App signed by`.
  - One of Apple's developer tools: with an Apple-signed Xcode, `<Xcode>/Contents/Developer/
    usr/bin/git ls-remote http://$IP:18083/x &`, which waits for a reply that does not come.
    Detail: `Process git-remote-http`, `App Ghostty` (not Xcode), `Signed by unnamed code`,
    `Interpreter signed by Apple`.

  Press `Ghostty,` (its subtitle is the app's signer), then `--prefix "$IP:<port>,"`. `$V db
  "select processName, appName, signer, appSigner from connection where remotePort in
  (18081, 18082, 18083)"`: `nc | Ghostty | Apple | Mitchell Hashimoto`, `job.swift | Ghostty
  | script, not signed | Mitchell Hashimoto`, `git-remote-http | Ghostty | unnamed code |
  Mitchell Hashimoto`.
- **A row whose connections differ.** From launch agents, so no app takes them: one running
  your own program named `nc` to `$IP:18092`, then `/bin/sh -c "sleep 200 | /usr/bin/nc $IP
  18091"`. The row reads `nc, 2 on this network, 2` with no signer, and its detail has no
  `Signed by`. Each connection's detail has its own: `Apple` and `unsigned`.
- **A file put in a bundle.** Build `Tool.app` with your own `Contents/MacOS/Tool`, `codesign
  -s - Tool.app`, then copy another program to `Contents/MacOS/dropper` and start it from a
  launch agent. Row `Tool, 1 on this network · ad hoc signed`; `Explain` shows the answer with
  no `Confirm` and stores nothing. With `Tool` itself running instead, and the dropper's
  connection gone, `Explain` offers `Confirm` and stores `ad-hoc:<hash>:<path of Tool.app>`.
- **A process that replaces itself.** A launch agent running `/bin/bash exec.sh $IP`, which
  does `exec 3<>/dev/tcp/$1/18095; sleep 12; exec /usr/bin/nc $1 18096 < <(sleep 300)`. `$V db
  "select pid, processName, signer, remotePort from connection where remotePort in (18095,
  18096)"`: one pid, `exec.sh | script, not signed | 18095` and `nc | Apple | 18096`.
- **One whose new program deletes its file.** The same agent with `exec <dir>/dropper $1 18096`
  in place of `nc`, where `dropper` is your own program that unlinks `argv[0]`, then connects
  and sleeps. The same query: one pid, `exec.sh | script, not signed | 18095` and `dropper | |
  18096`, with no signer. Row `dropper, 1 on this network, 1`, with no signer either.

- **A connection's direction.** With the broker. `$V connect named`, then its row: detail
  headed `<terminal> to example.com`, with `Destination` and `First contact`. A row open since
  before the copy started, from a local port of 49152 or above: `already open`, headed `<app>
  to <address>`, with `Destination` and `First contact`. On a lower local port with no
  listener: no tag, headed `<app> with <address>`, `Peer`, `Local port`, no `First contact`.
  `$V db "select direction, scope, count(*) from connection where ended is null group by
  direction, scope"`.
- **Owners of short-lived connections.** With the broker and the panel never opened. Run the
  `connect named` bytes with no hold (`{ printf '<its GET>'; sleep 0; } | nc -G 5 -p <port> <ip>
  80`) from a script, every 4 s for 120 s; `nc` lives 47 to 140 ms. Count the rows opened in
  the window with no owner: `select count(*) from connection where firstSeen >= '<start>' and
  firstSeen < '<end>' and (processName like 'pid %' or processName = 'unknown process')`, with
  and without `localPort in (<the ports>)`. `firstSeen` is UTC. An `nc` outlives the reading
  that names it, so this cannot show an owner lost by a process that exits while a reading
  resolves it: that rests on `testOwnersKeepTheirLinesWhenTheyExitWhileTheReadingResolvesThem`.
- **Incoming connections and a Tailscale peer.** On testmac, with `IP` its `inet 100.` address:
  `sleep 1700 | nc -lk $IP 18091 > /dev/null &` and `sleep 1700 | nc $IP 18091 > /dev/null &`,
  from a script in a terminal app. `-k` keeps the listener, which is what tells the accepted
  socket. Press the terminal's row: `$IP:<port>, incoming, TCP · connected · this network ·
  nc` is headed `<terminal> from $IP:<port>`, with `From`, `To port 18091`, `Reach this
  network` and no `First contact`. An `ssh` held from another Mac over Tailscale reads the
  same in the row `sshd-session: <login>@notty`: `incoming`, `To port 22`, `Reach this network`.

## Gotchas

- `nc` quits at the end of its standard input, and a background job in a script has none:
  feed it from `sleep`, or the connection is gone before the panel is read.
- Copies of macOS's own programs are killed at launch. Apple's programs with a team
  identifier run from anywhere, given the libraries their load paths expect: hence the
  `lib` link for `swift-frontend`.
- Xcode Service holds no connection, so its row in this tab rests on the unit test
  (`testAnAppAmongApplesDeveloperToolsReadsAsUnnamedCode` in `NetworkSnapshotTests`).
- A foreign executable inside a copy of a publisher's bundle rests on the unit tests
  (`testAConnectionIsSignedByItsOwnProcessAndItsAppApart`,
  `testAFileInABundleItsSignerDidNotSignTakesAwayTheRowsIdentity`): on testmac a new binary put
  in a copy of `Calculator.app`, unsigned or ad hoc, sat held at launch (state `S`, no CPU,
  and a program that only returns never returned), with macOS's `"Calculator" is damaged and
  can't be opened` alert on the screen, so it never opened a connection to read.
  One put in a bundle built on the machine runs, which is the recipe above.
- Incoming connections and the Tailscale peer's reach proven 2026-11-08 on testmac, run
  `2026-11-08T210232` (commit `c969c4d`); copy in the development Mac's
  `build/verify/runs/testmac-2026-11-08/`. `from the internet` needs a public peer, so it rests
  on the unit test (`testAnInboundConnectionReadsAsInbound`).
- Direction proven 2026-11-08 on the development Mac with the broker. Run `2026-11-08T222028`
  (commit `97096f3`): a seen opening, `Ghostty to example.com`, `direction` `outbound`. Run
  `2026-11-08T223300` (commit `edc856c`), a fresh launch: all 64 internet rows were already
  open and read outbound from their local ports, none unknown. `Herdr Core to
  160.79.104.10:443`, `First contact no`; `Google Chrome to 18.97.36.51:443`, `First contact
  yes`; `identityservicesd with [fe80:17::f86b:c51e:57bf:33c]:1024`, on a port below the range;
  `rapportd from 192.168.1.20:55421`, on a high port, among 128 sockets its listener claims.
  Listeners by family and a seen opening arriving after the row rest on unit tests. The `nc`
  pair over Tailscale does not connect on the development Mac.
- A host's prompt with no direction proven 2026-11-08 on testmac, run `2026-11-08T232714`
  (commit `25c7e20`): `Ghostty to 100.x.y.z:18091` shows `Destination` and `First contact`,
  and the recorded prompt's `facts` are `Protocol`, `Reach` and `Since`. Copy in the development
  Mac's `build/verify/runs/testmac-2026-11-08/`. An opening seen while a reading resolves owners
  rests on the unit test (`testAnOpeningSeenWhileAReadingResolvesOwnersReachesTheRowAndItsHistory`).
- The two unnamed rows look alike in the list; tell them apart by the `Process nc (pid
  ...)` fact against the pids `connect` printed.
- The panel lists open connections only, and a closed connection's detail keeps the state
  from when it was opened. A connection that closes before its outcome arrives shows the
  outcome in history and the log, never in the panel. example.com closed garbage and
  silent connections after 3 s and 14 s, so the unnamed cases use GitHub's SSH port,
  which holds them about two minutes. Time an open connection with `lsof -iTCP:<port>
  -sTCP:ESTABLISHED`, not with how long `nc` runs.
- The sniffer skips local-network destinations; a connection to the router never gets a
  name or a reason.
- The sniffer's DNS fallback names a connection from a UDP DNS reply it captured for
  that address in the last hour (the newest 4096 answers at most), if one of the Mac's resolvers sent it to this Mac and the
  address's record is for the question name or a CNAME target reached from it. `connect` looks example.com up over TCP so the fallback
  cannot name the garbage and silent connections; looking it up any other way first (a
  browser, `curl`, `nc example.com`) turns their outcome into `dns`.
- `outcome ... arrived with no live connection` debug lines are normal: the sniffer often
  names a flow before the socket table shows it.
- Connections already open when the dev copy started have no name (`open since before
  Tattle started`).
- An owner and its app read by pid, with no sweep of the process table, shown 2026-11-09 on
  the development Mac with the broker, dev copy at `ba0432b`, run `2026-11-09T192354`:
  `Herdr Core to example.com`, `Process nc (pid 89678)`, `App Herdr Core`, `Signed by Apple`,
  `App signed by Herdr, Inc.`, and in history `nc | example.com | http | Herdr Core | Apple |
  Herdr, Inc.`. The short-lived recipe above, five alternating 120-second windows per side:
  driven connections with no owner 1 of 150 at `7744536` and 0 of 149 at `ba0432b` (one `nc`
  exited with an error and left no row); all new rows with no owner 10 of 303 and 9 of 273,
  the rest TCP to the router's port 53, one per window as the driver's `dig +tcp` is, and to
  testmac's port 22. That shows no difference for processes that live 47 ms or more, and nothing
  about ones that exit sooner.
- Owners of processes that exit within a reading, simulated 2026-11-09 on testmac (debug build,
  not the app): a helper connects to a loopback listener and exits 26 to 42 ms later; 20 ms after
  the accept one reading is taken, with the helper's socket rewritten to a private address. In
  720 runs per side, in rotating order, the helper read as `pid <n>` 112 times at `7744536`, 126
  at `b6c21c7` and 174 at `ba0432b`. Whether a side ran first or last in a round moved its count
  more than which side it was: two fixed-order sets of 480 gave 55 and 58 at `7744536`, 68
  (run second) and 44 (run first) at `b6c21c7`. The harness was not kept.
- A process's own name for itself proven 2026-11-09 at `ba0432b`, run `2026-11-09T192510`:
  `exec -a` with `.`, `..` and `~` read as that text in the row and in `processName`, with no
  dependence on the app's working directory or home. A home folder (`~`, `~user`) or a relative
  path ending in `.` or `..` now reads as the program's file, and an absolute path keeps its last
  component as before; that rests on `testTheNameAProcessStartedUnderIsNotAPathToResolve`. At `ba0432b` an empty `argv[0]` did not
  reach the naming: `ProcessTable.parseArguments` took it for the padding after the executable's
  path, so the process was named after its next argument (`G` for `nc -G 5 ...`), or after its
  first environment string when it had none, and that string joined its arguments. The parser
  now skips the padding by its length; a real process with an empty `argv[0]` rests on
  `testAnEmptyFirstArgumentIsReadAsOne`, not yet on a run in the app.
- A connection's own signer proven 2026-11-08 on testmac, dev copy at `ebf12ca`, run
  `2026-11-08T105543`, copied to `build/verify/runs/testmac-2026-11-08/`.
- The relay and OHTTP rules read from the `rule` table at `969e6d3` on testmac, run
  `2026-11-08T122412`; no traffic to those hosts can be made on demand.
- A row whose connections differ, a file put in a bundle and a process that replaces itself
  proven 2026-11-08 on testmac, dev copy at `969e6d3`, run `2026-11-08T122412`; the bundle's own
  executable in run `2026-11-08T122957`. Copied to `build/verify/runs/testmac-2026-11-08/`.
- A process whose new program deletes its file proven 2026-11-08 on testmac, dev copy at
  `0749baf`, run `2026-11-08T141229`, copied to `build/verify/runs/testmac-2026-11-08/`.
