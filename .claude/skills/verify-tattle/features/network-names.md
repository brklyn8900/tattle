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
- `net-incoming`: a connection this Mac accepted carries a grey `incoming` tag. Its detail is
  headed `<app> from <peer>`, with `From` and `To port` in place of `Destination`, and no
  `First contact`; it does not count among addresses never seen before. A group row says `N
  from the internet` for those from public addresses. History keeps it in `isInbound`.
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

- **Incoming connections and a Tailscale peer.** On testmac, with `IP` its `inet 100.` address:
  `sleep 1700 | nc -lk $IP 18091 > /dev/null &` and `sleep 1700 | nc $IP 18091 > /dev/null &`,
  from a script in a terminal app. `-k` keeps the listener, which is what tells the accepted
  socket. Press the terminal's row: `$IP:18091, new, TCP · connected · this network · nc` and
  `$IP:<port>, incoming, TCP · connected · this network · nc`. The first has `Destination`,
  `Reach this network` and `First contact`; the second is headed `<terminal> from $IP:<port>`,
  with `From`, `To port 18091`, `Reach this network` and no `First contact`. `$V db "select
  processName, remoteAddress, remotePort, localPort, isInbound, scope from connection where
  localPort = 18091 or remotePort = 18091"`: `isInbound` 1 on the accepted row, `scope` `local`
  on both. An `ssh` held from another Mac over Tailscale reads the same in the row
  `sshd-session: <login>@notty`: `incoming`, `To port 22`, `Reach this network`.

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
- Incoming connections and the Tailscale peer proven 2026-11-08 on testmac, run `2026-11-08T210232` (commit `c969c4d`); copy in this Mac's
  `build/verify/runs/testmac-2026-11-08/`. `from the internet` needs a public peer,
  so it rests on the unit test (`testAnInboundConnectionReadsAsInbound`).
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
- A connection's own signer proven 2026-11-08 on testmac, dev copy at `ebf12ca`, run
  `2026-11-08T105543`, copied to `build/verify/runs/testmac-2026-11-08/`.
- The relay and OHTTP rules read from the `rule` table at `969e6d3` on testmac, run
  `2026-11-08T122412`; no traffic to those hosts can be made on demand.
- A row whose connections differ, a file put in a bundle and a process that replaces itself
  proven 2026-11-08 on testmac, dev copy at `969e6d3`, run `2026-11-08T122412`; the bundle's own
  executable in run `2026-11-08T122957`. Copied to `build/verify/runs/testmac-2026-11-08/`.
- A process whose new program deletes its file proven 2026-11-08 on testmac, dev copy at
  `0749baf`, run `2026-11-08T141229`, copied to `build/verify/runs/testmac-2026-11-08/`.
