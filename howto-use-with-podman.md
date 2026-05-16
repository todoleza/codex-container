## Podman workflow

Build both images from `codex-cli/`:

```bash
./gen-dist.sh
CONTAINER_CLI=podman ./scripts/build_container.sh
```

This produces:

- `codex`: the Fedora-based Codex runtime image
- `codex-firewall`: the lean Alpine firewall sidecar

Run Codex through the pod launcher:

```bash
./run-in-container.sh --work_dir /path/to/repo --full-auto
```

The launcher:

- creates a rootless Podman pod
- starts a privileged firewall sidecar in the pod
- programs IPv4 and IPv6 egress rules with `nftables`
- starts an unprivileged Codex container in the same pod network namespace

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
