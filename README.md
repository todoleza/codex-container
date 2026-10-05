# codex-cli in podman

This repo creates container with Codex CLI in a rootless Podman pod with:

- a Fedora-based Codex runtime image
- a minimal Alpine firewall sidecar
- a direct Podman launcher
- an experimental `podman kube play` launcher
- provides a working security-first container prototype
- optional SOCKS proxy relay support. The relay is disabled by default because
  it forwards to an existing host proxy and may be used by the agent for
  exfiltration of data.

The intended build flow is:

```bash
./codex-artifact.sh prepare
./build-images.sh
```

`codex-artifact.sh prepare` downloads the selected upstream
`codex-npm-<version>.tgz` asset from GitHub releases into
`.build-cache/upstream/codex/`, stages `dist/codex.tgz`, and writes
`dist/codex-artifact.env`. The container build consumes that staged archive and
does not run `pnpm` or `npm pack` locally.

The image build defaults to `buildah bud`; set `CONTAINER_CLI=podman` to use
Podman as an override. The runtime image is generated from `Dockerfile.in`;
`build-images.sh` is a compatibility entrypoint for the Python build driver.
It validates profile symlinks and expands the selected `container-deps/dnf/*.dnf`
components into separate DNF install layers. Runtime builds
also reuse a repo-local DNF cache at `.build-cache/dnf-fedora-44` by default;
set `DNF_CACHE_DIR=/path/to/cache` to share or relocate it. The DNF cache only
avoids repeated package downloads; the explicit builder layer cache is what
keeps unchanged `RUN dnf ...` steps from executing again.
Selected `container-deps/collections/*.yml` drop-ins are folded into an Ansible
collection requirements file and installed into the runtime image with
`ansible-galaxy collection install`.
The runtime image also installs the latest stable SOPS release binary by
default; pin it with `SOPS_VERSION=<version> ./build-images.sh`.

With no selector, the builder creates the lean `codex:default` image. Use
repeated or comma-separated `--profile` values to build exactly those profiles,
or `--all-profiles` (optionally with `--no-profile`). Available profiles are
`default`, `infra`, `python`, `media`, and `full`. Each successful build first
uses a candidate tag, rotates the existing image to `codex:prev-<profile>`, and
then promotes `codex:<profile>`; default also updates `codex:latest`. A failed
build does not rotate the current or previous image.

Generated evidence is retained under
`.build-cache/profiles/<profile>/Containerfile`, with supporting collection
requirements beside it. All profiles share `.build-cache/dnf-fedora-44` and the
builder's local layer store. `container-deps/copr/` accepts declarative `.copr`
files (`OWNER/PROJECT [CHROOT]`), while `container-deps/repos/` accepts literal
`.repo` files. Literal repositories do not automatically add their domains to
the firewall allowlist.

The firewall image installs one DNS resolver selected before image creation
with `CODEX_FIREWALL_DNS_TOOL=dig|kdig|drill`; the default is `dig`, which maps
to Alpine `bind-tools`. `kdig` maps to `knot-utils`, and `drill` maps to the
Alpine `drill` package.

More details on use are in [howto-use-with-podman.md](./howto-use-with-podman.md).

## Entry points

- `codex-artifact.sh`
  - build-side artifact command entrypoint
  - source Codex npm tarballs from GitHub releases
  - keep upstream artifacts out of the repository root
- `build-images.sh`
  - build-side image command
  - checks staged artifact freshness before building
- `run-in-container.sh`
  - primary launcher
  - uses `podman pod create` directly
  - current workable path
  - keeps Codex sandbox resources available inside the runtime image
  - defaults Codex itself to `--sandbox danger-full-access` and propagates that policy into the app container
  - defaults Codex to `--no-daemon`, avoiding a shared daemon socket and separately downloaded executable across ephemeral workspace containers
  - starts interactive shells in the mounted workspace via an image profile hook
  - builds the firewall allowlist from named domain categories, with explicitly omitted preset domains kept out by default
  - exposes the current firewall policy read-only inside the app container through `codex-firewall-policy`
  - loads launcher defaults from global, workspace, and explicit env files without overriding caller-provided environment
  - maps `CODEX_ENV_<NAME>` launcher/env-file variables into app-container `<NAME>` variables
  - re-execs long-lived or mutating invocations from a runtime snapshot so later edits to the launcher do not affect the active command
  - saves the staged Codex CLI version onto the runtime image at build time, then labels spawned pods and app containers with that image version and the latest GitHub release version seen at spawn time
  - can start an optional two-hop `socat` relay, with a dedicated proxy container owning the host-side hop and the firewall sidecar bridging `localhost:1080` to `/run/codex-proxy/proxy.sock`
  - can start named sidecar containers in the Codex pod, with sidecar-only env prefixes for API proxies and similar local services
  - supports environment overrides for extra Podman args and startup-summary hold time
  - provides launcher commands for list/status/name, normal and privileged app exec, firewall exec, copy/pull, replace, respawn, and destroy
- `run-in-podman-kube.sh` - experimental
  - draft launcher
  - uses `podman kube play`
  - explored as an alternative to pod commands, is too complicated and interactivity gets blocked by Fedora selinux policy

## Layout

- `Dockerfile.in`
  - Fedora Codex runtime image template
- `container-profiles/`
  - relative-symlink membership for DNF, COPR, repository, and collection catalogs
- `container-deps/`
  - shared `dnf`, `copr`, `repos`, and `collections` catalogs selected by profiles
- `container-runtime/`
  - image-side Codex wrapper and shell profile hook
- `Dockerfile.firewall`
  - Alpine firewall sidecar image
- `firewall/`
  - sidecar command scripts and helpers
- `howto-use-with-podman.md`
  - usage notes and troubleshooting
- `podman-kube/`
  - draft kube-play notes and template
