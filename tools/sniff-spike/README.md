# sniff-spike

Build-order step 0 from the [proposal](../../docs/proposal.md): measures how many outbound
connections a BPF sniffer can put a real name on, on this machine, before the Network tab
depends on it.

It reads packets from `/dev/bpf*` and names each new outbound connection from, in order of
preference: the TLS ClientHello's server name (TCP), the same name inside a decrypted QUIC
Initial packet (UDP), the Host header of plaintext HTTP, or a DNS reply seen earlier for
that address. It never writes to the network and keeps no packet contents; the optional
log holds one line per connection with the names found.

## Run

    swift build -c release
    sudo .build/release/sniff-spike --every 60 --duration 86400 --log ~/spike.jsonl

`sudo` is only for opening `/dev/bpf*`. The summary prints every `--every` seconds and at
exit; Ctrl-C ends early. Connections to private, loopback, link-local and multicast
addresses count as `local` and are left out of the percentages.

## Reading the summary

- `named by`: how each remote connection got its name. `sni`, `quic` and `http` come from
  the connection itself; `dns` means only an earlier DNS reply named the address; `none`
  means nothing did.
- `dns alone would name`: the share a DNS-only approach would cover, for comparison.
- `quic failures`: Initial packets that could not be decrypted, by reason.
- `unnamed top`: the addresses and ports that stayed unnamed most often.
