## Implemented design

### Goal

Run Codex in an unprivileged container while enforcing outbound network policy from a separate firewall sidecar that shares the pod network namespace.

### Images

- `Dockerfile`: Fedora-based Codex runtime image
- `Dockerfile.firewall`: minimal Alpine firewall image
- `build-images.sh`: top-level image builder consuming `dist/codex.tgz`

The Codex image contains Codex and developer tooling only. The firewall image contains only the scripts and packages needed to manage nftables-based IPv4/IPv6 egress policy.

### Pod layout

`run-in-container.sh` creates one rootless Podman pod containing:

- `codex_*_fw`
  - runs as root
  - holds `NET_ADMIN` and `NET_RAW`
  - owns firewall state under `/etc/codex-firewall`
- `codex_*`
  - runs as the host uid/gid
  - uses `--cap-drop=ALL`
  - mounts the repo and `~/.codex`

### Firewall model

The sidecar uses `nftables` in the `inet` family so IPv4 and IPv6 are handled together.

- allowed domains are stored in `domains.txt`
- explicit IPv4 entries are stored in `ipv4.txt`
- explicit IPv6 entries are stored in `ipv6.txt`
- `firewall-reload` resolves `A` and `AAAA` records, reads resolver IPs from `/etc/resolv.conf`, and rebuilds the nftables ruleset

Traffic policy:

- allow loopback
- allow established and related traffic
- allow DNS only to configured resolvers
- allow outbound TCP/UDP only to explicitly allowed IPv4/IPv6 destinations
- reject everything else

IPv6 is filtered when present. Missing host IPv6 connectivity is acceptable; unfiltered IPv6 egress is not.

### Control flow

The wrapper programs the firewall with `podman exec`:

1. `firewall-init`
2. `firewall-allow-domain ...`
3. `firewall-allow-address ...` for any extra IPv4/IPv6 entries
4. `firewall-reload`

Only after those steps succeed does it start the Codex container.

### Distribution shapes

Two user-facing entrypoints are prepared:

- `run-in-container.sh` for direct `podman pod create` orchestration with explicit pod, infra, firewall, and app names
- `run-in-podman-kube.sh` for a draft `podman kube play` workflow using Podman annotations for `keep-id` and infra naming
