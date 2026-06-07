# codex-cli in podman

This repo creates container with Codex CLI in a rootless Podman pod with:

- a Fedora-based Codex runtime image
- a minimal Alpine firewall sidecar
- a direct Podman launcher
- an experimental `podman kube play` launcher
- provides a working security-first container prototype
- although the pod exposes socks proxy on port 1080, it is a plain forward to existing proxy. **It may be used by the agent for exfiltration of data.**

The intended build flow is:

```bash
./gen-dist.sh
CONTAINER_CLI=podman ./build-images.sh
```

`gen-dist.sh` stages `dist/codex.tgz`. The container build consumes that archive and does not run `pnpm` locally.

The runtime image is generated from `Dockerfile.in`; `build-images.sh` expands
sorted `container-deps/*.dnf` drop-ins into separate DNF install layers. Runtime
builds reuse a repo-local DNF cache at `.build-cache/dnf-fedora-44` by default;
set `DNF_CACHE_DIR=/path/to/cache` to share or relocate it.

More details on use are in [howto-use-with-podman.md](./howto-use-with-podman.md).

## Entry points

- `run-in-container.sh`
  - primary launcher
  - uses `podman pod create` directly
  - current workable path
  - keeps Codex sandbox resources available inside the runtime image
  - defaults Codex itself to `--sandbox danger-full-access` and prints the active policy on startup
  - starts an optional two-hop `socat` relay, with a dedicated proxy container owning the host-side hop and the firewall sidecar bridging `localhost:1080` to `/run/codex-proxy/proxy.sock`
  - supports environment overrides for extra Podman args and startup-summary hold time
  - opens an interactive `bash` in the container when no command is given
- `run-in-podman-kube.sh` - experimental
  - draft launcher
  - uses `podman kube play`
  - explored as an alternative to pod commands, is too complicated and interactivity gets blocked by Fedora selinux policy

## Layout

- `Dockerfile.in`
  - Fedora Codex runtime image, with DNF package groups included from `container-deps/`
- `Dockerfile.firewall`
  - Alpine firewall sidecar image
- `firewall/`
  - sidecar command scripts and helpers
- `howto-use-with-podman.md`
  - usage notes and troubleshooting
- `podman-kube/`
  - draft kube-play notes and template
