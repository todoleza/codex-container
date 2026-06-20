## Implemented design

### Goal

Run Codex in an unprivileged container while enforcing outbound network policy from a separate firewall sidecar that shares the pod network namespace.

### Images

- `Dockerfile.in`: template for the generated Fedora-based Codex runtime image
- `container-deps/`: globbed DNF package drop-ins for runtime install layers
- `Dockerfile.firewall`: minimal Alpine firewall image
- `build-images.sh`: top-level Buildah-first image builder consuming `dist/codex.tgz`

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
- `firewall-reload` resolves `A` and `AAAA` records, reads resolver IPs from `/etc/resolv.conf`, records the effective runtime view, and rebuilds the nftables ruleset

Traffic policy:

- allow loopback
- allow established and related traffic
- allow DNS only to configured resolvers
- allow outbound TCP/UDP only to explicitly allowed IPv4/IPv6 destinations
- reject everything else

IPv6 is filtered when present. Missing host IPv6 connectivity is acceptable; unfiltered IPv6 egress is not.

### Agent internet access policy

`run-in-container.sh` composes the default domain allowlist from named
categories instead of a single flat string. The categories mirror common Codex
agent dependency access needs while keeping broad vendor and legacy endpoints
separate:

- default categories: `openai`, `source_control`, `os_packages`, `containers`,
  `language_packages`, `jvm_dotnet`, and `schema_docs`
- opt-in broad vendor category: `vendor_opt_in`
- explicitly omitted legacy domains: `bower.io`, `continuum.io`,
  `jcenter.bintray.com`, `rubyforge.org`, and `rvm.io`

The SOCKS relay is disabled by default. It remains available as an explicit
operator opt-in, but it changes the enforcement point from the sidecar's
domain-resolved destination list to the host-side proxy policy.

### Runtime policy visibility

The firewall state directory is host-backed and shared by the pod:

- the firewall sidecar mounts it read-write at `/etc/codex-firewall`
- the Codex app container mounts it read-only at `/run/codex-firewall-policy`
- `codex-firewall-policy` prints the current configured and resolved policy

Manual `fwenter` changes are visible to the app after the relevant
`firewall-allow-*`, `firewall-reload`, or `firewall-lift` command updates the
shared state. `firewall-lift` deletes only the `inet codex_firewall` table and
records `CODEX_FIREWALL_MODE=lifted`; `firewall-reload` restores enforcement
from the configured policy and records `CODEX_FIREWALL_MODE=enforced`.

### Control flow

The wrapper programs the firewall with `podman exec`:

1. `firewall-init`
2. `firewall-allow-domain ...`
3. `firewall-allow-address ...` for any extra IPv4/IPv6 entries
4. `firewall-reload`

Only after those steps succeed does it start the Codex container.

### Launcher defaults and stability

`run-in-container.sh` can load optional dotenv-style env files before applying
its built-in defaults. The default global file is
`$HOME/.local/share/codex-container/env`, the default workspace file is
`$WORK_DIR/.codex-container.env`, and `CODEX_CONTAINER_ENV_FILES` can name
additional colon-separated files. Later env files override earlier env files,
but caller-provided environment variables stay strongest.

For long-lived or mutating commands, the launcher re-execs through a runtime
snapshot under `${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/codex-container` so edits
to the source script after invocation do not affect that active command.
Short read-only commands (`help`, `list`, `name`, `status`) do not snapshot.

### Distribution shapes

Two user-facing entrypoints are prepared:

- `run-in-container.sh` for direct `podman pod create` orchestration with explicit pod, infra, firewall, and app names
- `run-in-podman-kube.sh` for a draft `podman kube play` workflow using Podman annotations for `keep-id` and infra naming
