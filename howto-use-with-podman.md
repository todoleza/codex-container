## Podman workflow

Build both images from `codex-cli/`:

```bash
./gen-dist.sh
CONTAINER_CLI=podman ./scripts/build_container.sh
```

`gen-dist.sh` is the step that stages `dist/codex.tgz`. `build_container.sh` now only consumes that archive; it does not run `pnpm`, rebuild the package, or repack anything on its own.

This produces:

- `codex`: the Fedora-based Codex runtime image
- `codex-firewall`: the lean Alpine firewall sidecar

Run Codex through the primary pod launcher:

```bash
./run-in-container.sh --work_dir /path/to/repo --full-auto
```

The direct launcher creates a pod with stable human-readable names:

- pod: `codex-<workspace>-<hash>`
- infra: `codex-<workspace>-<hash>-infra`
- firewall: `codex-<workspace>-<hash>-fw`
- app: `codex-<workspace>-<hash>-app`

The launcher:

- creates a rootless Podman pod
- starts a privileged firewall sidecar in the pod
- programs IPv4 and IPv6 egress rules with `nftables`
- starts an unprivileged Codex container in the same pod network namespace

There is also a `podman kube play` path:

```bash
./run-in-podman-kube.sh --work_dir /path/to/repo --full-auto
```

That path renders a temporary kube manifest, sets `io.podman.annotations.userns=keep-id`, sets `io.podman.annotations.infra.name=<pod>-infra`, and then configures the firewall sidecar with `podman exec`.

Treat the kube-play path as a draft, not as a supported or confirmed-working deployment shape. It exists to capture the current experiment, not as the recommended way to run this prototype.

Optional environment variables:

```bash
CONTAINER_IMAGE=codex
FIREWALL_CONTAINER_IMAGE=codex-firewall
OPENAI_ALLOWED_DOMAINS="api.openai.com auth.openai.com chatgpt.com"
EXTRA_ALLOWED_DOMAINS="deb.debian.org"
EXTRA_ALLOWED_IPV4="1.1.1.1 8.8.8.0/24"
EXTRA_ALLOWED_IPV6="2606:4700:4700::1111 2001:4860:4860::/48"
```

The firewall sidecar is managed with `podman exec`. Useful commands:

```bash
podman exec <firewall-container> firewall-list
podman exec <firewall-container> firewall-allow-domain example.com
podman exec <firewall-container> firewall-allow-address 203.0.113.7
podman exec <firewall-container> firewall-allow-address 2001:db8::7
podman exec <firewall-container> firewall-reload
```
