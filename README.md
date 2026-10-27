# Tattle

A macOS menu bar app that shows what your Mac is doing and explains it in plain language:
network connections, running processes, listening ports, and startup items, each with who
signed it, who owns the other end, and why it is probably there.

Tattle is an explainer, not a firewall and not a system monitor. It makes no network calls
of its own: no telemetry, no update check, no cloud lookups. The one way anything leaves
your machine is an "explain" button you click, which sends a single redacted item to an LLM
you already have, through a command you configured. Design in the
[proposal](docs/proposal.md); decisions in the [ADRs](docs/adr/).

## Status

The four tabs (Network, Processes, Ports, Startup) and the explain path are complete as
proposed. There are no binaries: build from source with the steps below, on macOS 14 or
later. Ad-hoc signed builds need the first-launch allowance under Privacy & Security.

Not there yet: a LAN tab, per-page browser attribution, a search bar, a "started by"
filter on processes, and any kind of blocking (by design the last; see the proposal).

## Build

Requires macOS 14 or later and Xcode 26 or its command line tools.

    make app       # build, bundle and sign build/Tattle.app
    make install   # copy it to /Applications
    make test

    make run       # build and open the dev copy, build/TattleDev.app
    make stop      # quit the dev copy
    make log       # stream both copies' logs

The dev copy is a separate app, "Tattle Dev" (`io.github.eladefrati.tattle.dev`), with
its own data in `~/Library/Application Support/Tattle Dev/` and its own permission
grants, so `make run` never replaces or quits a release build that is running.

Releases are ad-hoc signed, so macOS blocks the first launch; allow it under System
Settings, Privacy & Security. With an Apple Development identity in your keychain, `make
app` signs with it instead, which keeps permission grants across rebuilds.

## Packet access

Connection names come from the first packets of each connection, which only root may
read. The Network tab's "Allow packet access" installs a small launch daemon, the
packet-access broker, that opens the capture device read-only and hands it to Tattle: it
answers only a caller that runs as the user who installed it, carries Tattle's signature,
and runs with the hardened runtime. It is installed and removed through the administrator
password dialog, with the exact plist shown first, and is removable from the Startup tab
as well. Without it the Network tab shows addresses
instead of names. Design and reasoning in [ADR-0003](docs/adr/0003-bpf-descriptor-broker.md).

With an Apple Development identity the broker recognises Tattle by team and bundle
identifier, the release app's or the dev copy's, which survive rebuilds. An ad-hoc build is recognised by its code hash, which
changes with every rebuild; Packet access then says the installed broker is from another
build and installs it again in one dialog.

## License

MIT. Bundled data carries its own licenses, listed in the proposal.
