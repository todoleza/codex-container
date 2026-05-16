## `podman kube play` workflow

`run-in-podman-kube.sh` renders a temporary Podman-compatible kube manifest and starts the same two-container pod shape as `run-in-container.sh`:

- a rootless pod with `keep-id`
- a named infra container
- a `firewall` sidecar with `NET_ADMIN`
- a `codex` workload container with all capabilities dropped

The manifest is rendered per workspace because it needs concrete host paths and a stable pod name derived from the workspace path.

Expected object names:

- pod: `codex-<workspace>-<hash>`
- infra: `codex-<workspace>-<hash>-infra`
- firewall container: `<pod>-firewall`
- app container: `<pod>-codex`

Run it like this:

```bash
./run-in-podman-kube.sh --work_dir /path/to/repo --full-auto
```
