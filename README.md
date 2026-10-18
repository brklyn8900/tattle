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

Early. Nothing to use yet.

## Build

Requires macOS 14 or later and Xcode 26 or its command line tools.

    make app       # build, bundle and sign build/Tattle.app
    make install   # copy it to /Applications
    make test

Releases are ad-hoc signed, so macOS blocks the first launch; allow it under System
Settings, Privacy & Security. With an Apple Development identity in your keychain, `make
app` signs with it instead, which keeps permission grants across rebuilds.

## License

MIT. Bundled data carries its own licenses, listed in the proposal.
