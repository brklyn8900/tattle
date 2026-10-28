# Architecture decision records

Each record states one decision and the context it was made in. The
[proposal](../proposal.md) is the design as accepted on 2026-10-18 and is not edited after
acceptance. Where a record and the proposal disagree, the record holds.

| ADR | Decision | Proposal sections it changes |
|---|---|---|
| [0001](0001-sniffer-coverage.md) | Name a connection from the connection itself first: TLS SNI, the QUIC Initial, the HTTP Host header. A name from DNS replies is a fallback, marked "from DNS". | Network (Observe), Build order step 0 |
| [0002](0002-login-items-full-disk-access.md) | Read the login-items database with Full Disk Access, asked for from the Startup tab. Sign builds with a stable identity so the grant survives rebuilds. | Startup (Observe), Distribution |
| [0003](0003-bpf-descriptor-broker.md) | Keep `/dev/bpf*` root-only. A root launch daemon checks the caller and hands it one capture descriptor over XPC. | Privileges, Non-goals (privileged helper), Build order step 5 |

Some proposal details changed without a record:

- The preset commands for Explain differ from the proposal's LLM provider section.
  `ShellProvider.presets` in `Sources/tattle/Explain/Provider.swift` has the current ones.
- IP block owner data (iptoasn) is not built. `tracker-radar.json` and `apple-hosts.json`
  in `Resources/knowledge/` ship with no rules.
