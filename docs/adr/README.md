# Architecture decision records

Each record states one decision and the context it was made in. The [PRD](../PRD.md)
and the [design](../design.md) are kept current with them.

| ADR | Decision | Sections it changes |
|---|---|---|
| [0001](0001-sniffer-coverage.md) | Name a connection from the connection itself first: TLS SNI, the QUIC Initial, the HTTP Host header. A name from DNS replies is a fallback, marked "from DNS". | design: Network; PRD: Network, Build order step 0 |
| [0002](0002-login-items-full-disk-access.md) | Read the login-items database with Full Disk Access, asked for from the Startup tab. Sign builds with a stable identity so the grant survives rebuilds. | design: Startup; PRD: Startup, Distribution |
| [0003](0003-bpf-descriptor-broker.md) | Keep `/dev/bpf*` root-only. A root launch daemon checks the caller and hands it one capture descriptor over XPC. | design: Privileges; PRD: Non-goals (privileged helper), Network, Startup, Distribution, Build order step 5 |
