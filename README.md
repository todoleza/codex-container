# Codex Podman Prototype

This directory is a stripped-down prototype for running Codex in a rootless Podman pod with:

- a Fedora-based Codex runtime image
- a minimal Alpine firewall sidecar
- a direct Podman launcher
- an experimental `podman kube play` launcher

The intended build flow is:

```bash
./gen-dist.sh
CONTAINER_CLI=podman ./build-images.sh
```

`gen-dist.sh` stages `dist/codex.tgz`. The container build consumes that archive and does not run `pnpm`.

## Entry points

- `run-in-container.sh`
  - primary launcher
  - uses `podman pod create` directly
  - current workable path
  - keeps Codex sandbox resources available inside the runtime image
  - defaults Codex itself to `--sandbox danger-full-access` and prints the active policy on startup
  - supports environment overrides for extra Podman args and startup-summary hold time
  - opens an interactive `bash` in the container when no command is given
- `run-in-podman-kube.sh`
  - draft launcher
  - uses `podman kube play`
  - not a confirmed workable solution yet

## Layout

- `Dockerfile`
  - Fedora Codex runtime image
- `Dockerfile.firewall`
  - Alpine firewall sidecar image
- `firewall/`
  - sidecar command scripts and helpers
- `howto-use-with-podman.md`
  - usage notes and troubleshooting
- `podman-kube/`
  - draft kube-play notes and template
