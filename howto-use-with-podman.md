## Podman workflow

Build both images from `codex-container/`:

```bash
./codex-artifact.sh prepare
./build-images.sh
```

`codex-artifact.sh prepare` stages `dist/codex.tgz` from the upstream GitHub
release asset named `codex-npm-<version>.tgz`, for example
`codex-npm-0.142.0-alpha.7.tgz`. Downloaded upstream artifacts live under
`.build-cache/upstream/codex/` instead of the repository root. `build-images.sh`
only consumes the staged archive; it does not run `pnpm`, rebuild the package,
or repack anything on its own.

Artifact commands:

```bash
./codex-artifact.sh prepare
./codex-artifact.sh prepare type alpha
./codex-artifact.sh prepare version 0.142.0-alpha.7
./codex-artifact.sh status
./codex-artifact.sh clean
```

The default artifact type is `release`, which selects the latest non-prerelease
GitHub release. `type alpha` selects the latest upstream alpha prerelease.
GitHub does not provide a `/releases/latest` equivalent for prereleases, so the
alpha lookup uses the releases list endpoint in small pages and stops at the
first matching alpha prerelease. `version VERSION` selects the exact
`rust-v<VERSION>` GitHub tag.

`codex-artifact.sh status` prints the staged artifact plus latest release and
latest alpha status in one report. Upstream status checks use a 2 second curl
timeout by default; override it with `CODEX_ARTIFACT_STATUS_TIMEOUT=SECONDS`.
`build-images.sh` checks whether the staged artifact is older than the latest
upstream version for its artifact type with a 1 second curl timeout; override it
with `CODEX_ARTIFACT_BUILD_TIMEOUT=SECONDS`. If the build-time check cannot
complete, the build continues with a warning. If the staged artifact is known to
be stale, an interactive terminal asks whether to refresh, continue, or abort.
In batch mode it does not prompt and fails by default. Batch mode is enabled by
either `--batch`, `--non-interactive`, `CODEX_CONTAINER_BATCH=1`,
`INTERACTIVE=0`, or non-TTY stdin. Override stale handling with
`CODEX_ARTIFACT_STALE_POLICY=continue|refresh|fail`.

The runtime build is generated from `Dockerfile.in`. Sorted
`container-deps/*.dnf` drop-ins become separate DNF install layers, and
`build-images.sh` enables builder layer caching explicitly. It also mounts a
persistent DNF cache from `.build-cache/dnf-fedora-44` by default. The default
builder is `buildah bud`; set `CONTAINER_CLI=podman` to use Podman as an
override. Override the DNF cache location with
`DNF_CACHE_DIR=/path/to/cache ./build-images.sh`. The mounted DNF cache reduces
package downloads, while the builder layer cache is what skips unchanged DNF
install steps.

The runtime image includes `age` from Fedora packages and the latest stable
SOPS release binary by default. Pin SOPS with
`SOPS_VERSION=<version> ./build-images.sh`.

The firewall image resolver is selected before image creation:

```bash
CODEX_FIREWALL_DNS_TOOL=dig ./build-images.sh
CODEX_FIREWALL_DNS_TOOL=kdig ./build-images.sh
CODEX_FIREWALL_DNS_TOOL=drill ./build-images.sh
```

`dig` is the default and installs Alpine `bind-tools`. `kdig` installs
`knot-utils`; `drill` installs the small Alpine `drill` package. The selected
tool is baked into the firewall image as `CODEX_FIREWALL_DNS_TOOL`, and can
still be overridden at runtime for experiments when the binary exists.

This produces:

- `codex`: the Fedora-based Codex runtime image
- `codex-firewall`: the lean Alpine firewall sidecar

Run Codex through the primary pod launcher:

```bash
./run-in-container.sh --wd /path/to/repo --full-auto
```

If you run it without a command, it starts Codex:

```bash
./run-in-container.sh
```

eventually set up a symlink:

```bash
ln -sr ./run-in-container.sh ~/bin/codex.sh
```

The direct launcher creates a pod with stable human-readable names:

- pod: `codex-<workspace>-<hash>`
- infra: `codex-<workspace>-<hash>-infra`
- firewall: `codex-<workspace>-<hash>-fw`
- proxy: `codex-<workspace>-<hash>-proxy`
- app: `codex-<workspace>-<hash>-app`

The proxy container is optional functionality that exposes the host's
`localhost:1080` in the restricted network namespace of the pod. It is disabled
by default because it changes the network boundary from domain-filtered direct
egress to whatever the host-side proxy permits.

The launcher:

- creates a rootless Podman pod
- starts a privileged firewall sidecar in the pod
- programs IPv4 and IPv6 egress rules with `nftables`
- starts an unprivileged Codex container in the same pod network namespace
- propagates the workstation timezone into both containers via `TZ`, falling back to `UTC` if detection fails
- propagates `CODEX_WORKDIR`, `CODEX_SANDBOX_MODE`, `CODEX_APPROVAL_POLICY`, `CODEX_DANGEROUS_BYPASS`, and launcher-computed `CODEX_EXTRA_ADD_DIRS` into the app container
- mounts the live firewall policy into the app container read-only and exposes it through `codex-firewall-policy`
- loads optional env files before applying launcher defaults
- snapshots the launcher into the runtime directory for long-lived or mutating commands
- labels new pods and app containers with `codex.cli.version` from runtime-image metadata and `codex.cli.latest` from the GitHub releases API
- prints a short startup summary including the current Codex sandbox/approval policy and domain allowlist

The runtime image includes a `codex` wrapper in `/usr/local/bin`. Any `codex`
process started inside the app container gets the propagated sandbox and
approval defaults unless the command line already sets them. For linked Git
worktrees, the launcher mounts the shared Git metadata and the wrapper passes it
to Codex with `--add-dir` unless the command line already supplies `--add-dir`.
The image also installs a shell profile hook that changes interactive shells into
the propagated workspace path, so Codex sees the same absolute path inside the
container that the host-side session index records.

The launcher parses `--wd` and `--id` as its own dash options. Other dash
arguments are passed to Codex, so `--help` still means Codex CLI help. Use the
non-dash `help` command for launcher help:

```bash
./run-in-container.sh help
./run-in-container.sh --help
```

Launcher commands are selected by the first recognized non-dash argument:

```bash
./run-in-container.sh list
./run-in-container.sh --id 1 status
./run-in-container.sh name parent-leaf
./run-in-container.sh --wd /path/to/repo spawn
./run-in-container.sh --id 1 enter
./run-in-container.sh --id parent-leaf shell pwd
./run-in-container.sh --id 1 rootenter
./run-in-container.sh --id parent-leaf rootshell dnf install -y strace
./run-in-container.sh --id 1 fwenter
./run-in-container.sh --id parent-leaf fwshell firewall-list
./run-in-container.sh --id 1 copy ./local.txt notes/local.txt
./run-in-container.sh --id parent-leaf pull notes/out.txt ./out.txt
./run-in-container.sh --id 1 replace --model gpt-5
./run-in-container.sh --id 1 respawn
./run-in-container.sh rm parent-leaf
```

`spawn` starts the workspace pod in the background and exits. `enter` runs an
interactive TTY command in the workspace's original absolute path, defaulting
to `bash`.
`shell` keeps stdin open but does not allocate a TTY, so `shell pwd` prints
that path. `rootenter` and `rootshell` run privileged root commands in
the app container from `/root`; use them for live container maintenance and
ad-hoc dependency probing, not as durable image changes. `fwenter` and
`fwshell` do the same TTY and non-TTY operations in the firewall container;
`fwenter` defaults to `bash` and `fwshell` requires a command. `copy`/`push`
copy host paths into the container; `pull`/`fetch` copy container paths out.
Relative container copy paths resolve under the same workspace path; local copy
paths such as `./file` are resolved to absolute host paths before calling
`podman cp`.

`list` shows registered workspaces by stable runtime sequence number, slug alias,
state, start time, and path. `--id` can select a workspace by that sequence
number, by its `parent-leaf` alias, by a known container/pod name, or by an
absolute path. If an alias matches more than one workspace, use the numeric id.
For launcher-owned commands that do not otherwise accept payload arguments,
the id can also come after the command, as in `status 1` or `rm parent-leaf`.
The registry lives under
`${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/codex-container/workspaces` and is made
from symlinks into per-workspace state directories.

If a workspace container is already running and you start the launcher without
an explicit launcher command, it enters the existing container. This also
applies from subdirectories after workspace-root resolution, so starting from a
nested path jumps to the parent workspace session. `replace` kills any existing
workspace pod before normal startup. `respawn` kills any existing workspace pod,
starts a fresh pod in the background, and exits without attaching. If there is
nothing to kill, these commands print that and continue.

After the app container starts successfully, it stays running when a Codex or
shell session exits. Use `destroy`, `rm`, or `kill` when you want to remove the
workspace pod.

For a short command available outside this repo, symlink the launcher:

```bash
ln -sr ./run-in-container.sh /tmp/codex.sh
/tmp/codex.sh --id 1 enter
```

There is also a `podman kube play` path:

```bash
./run-in-podman-kube.sh --work_dir /path/to/repo --full-auto
```

That path renders a temporary kube manifest, sets `io.podman.annotations.userns=keep-id`, sets `io.podman.annotations.infra.name=<pod>-infra`, and then configures the firewall sidecar with `podman exec`.
See README.md for general info about kube play.

Treat the kube-play path as a draft, not as a supported or confirmed-working deployment shape. It exists to capture the current experiment, not as the recommended way to run this prototype.

Optional environment variables:

```bash
CONTAINER_IMAGE=codex
FIREWALL_CONTAINER_IMAGE=codex-firewall
PROXY_CONTAINER_IMAGE=codex-firewall
PROXY_ENABLE=0
PROXY_RUNTIME_DIR_HOST=/run/user/$(id -u)/codex-<workspace>-<hash>-proxy
PROXY_RUNTIME_DIR=/run/codex-proxy
PROXY_SOCKET_PATH=/run/codex-proxy/proxy.sock
PROXY_LISTEN_HOST=localhost
PROXY_LISTEN_PORT=1080
PROXY_UPSTREAM_HOST=localhost
PROXY_UPSTREAM_PORT=1080
SIDECARS=""
SIDECAR_hcloud_IMAGE=localhost/hcloud-acl-proxy:latest
SIDECAR_hcloud_ENV_PREFIX=HCLOUD_PROXY_ENV_
SIDECAR_hcloud_RUN_ARGS=""
SIDECAR_hcloud_COMMAND=""
CODEX_FIREWALL_POLICY_DIR=/run/codex-firewall-policy
FIREWALL_POLICY_RUNTIME_DIR_HOST=/run/user/$(id -u)/codex-<workspace>-<hash>-policy
CODEX_CONTAINER_GLOBAL_ENV_FILE=$HOME/.local/share/codex-container/env
CODEX_CONTAINER_WORKSPACE_ENV_FILE=/path/to/repo/.codex-container.env
CODEX_CONTAINER_ENV_FILES=""
CODEX_SANDBOX_MODE=danger-full-access
CODEX_APPROVAL_POLICY=on-request
CODEX_DANGEROUS_BYPASS=0
CODEX_RELEASE_API_URL=https://api.github.com/repos/openai/codex/releases/latest
CODEX_RELEASE_API_TIMEOUT_SECONDS=5
CODEX_RELEASE_CHECK_ON_SPAWN=1
PODMAN_POD_CREATE_ARGS=""
PODMAN_FIREWALL_RUN_ARGS=""
PODMAN_CODEX_RUN_ARGS=""
PODMAN_EXEC_ARGS=""
CONTAINER_EXEC_COMMAND=""
STARTUP_SUMMARY_HOLD_SECONDS=2
CODEX_ALLOWED_DOMAIN_CATEGORIES="openai source_control os_packages containers language_packages jvm_dotnet schema_docs"
CODEX_ALLOWED_DOMAINS_OPENAI="api.openai.com auth.openai.com chatgpt.com"
CODEX_ALLOWED_DOMAINS_SOURCE_CONTROL="github.com githubusercontent.com api.github.com gitlab.com bitbucket.org"
CODEX_ALLOWED_DOMAINS_OS_PACKAGES="alpinelinux.org archlinux.org centos.org debian.org fedoraproject.org ppa.launchpad.net ubuntu.com packages.microsoft.com"
CODEX_ALLOWED_DOMAINS_CONTAINERS="docker.com docker.io ghcr.io gcr.io mcr.microsoft.com quay.io"
CODEX_ALLOWED_DOMAINS_LANGUAGE_PACKAGES="cpan.org crates.io golang.org goproxy.io haskell.org hex.pm metacpan.org nodejs.org npmjs.com npmjs.org packagist.org pkg.go.dev pub.dev pypa.io pypi.org pypi.python.org pythonhosted.org ruby-lang.org rubygems.org rubyonrails.org rustup.rs yarnpkg.com"
CODEX_ALLOWED_DOMAINS_JVM_DOTNET="apt.llvm.org dot.net dotnet.microsoft.com gradle.org maven.org nuget.org"
CODEX_ALLOWED_DOMAINS_SCHEMA_DOCS="json-schema.org json.schemastore.org"
CODEX_ALLOWED_DOMAINS_VENDOR_OPT_IN="anaconda.com apache.org azure.com cocoapods.org eclipse.org google.com hashicorp.com java.com java.net k8s.io launchpad.net microsoft.com oracle.com packagecloud.io sourceforge.net spring.io swift.org visualstudio.com"
CODEX_OMITTED_DOMAINS="bower.io continuum.io jcenter.bintray.com rubyforge.org rvm.io"
OPENAI_ALLOWED_DOMAINS=""
EXTRA_ALLOWED_DOMAINS="deb.debian.org"
EXTRA_ALLOWED_IPV4="1.1.1.1 8.8.8.0/24"
EXTRA_ALLOWED_IPV6="2606:4700:4700::1111 2001:4860:4860::/48"
```

Env files are optional dotenv-style files with `KEY=VALUE` lines, blank lines,
and `#` comments. They are data files, not shell scripts; command substitution,
variable expansion, and `export KEY=VALUE` syntax are not evaluated. Invalid
lines stop startup with a clear error.

The launcher resolves the workspace path before loading the workspace env file.
If the requested directory is inside a Git worktree, the workspace is the Git
top-level directory. Outside Git, the launcher walks upward to the nearest
parent containing `.codex-container.env`; if none is found, it uses the
requested directory as-is. When no marker identifies the parent, implicit
workspace selection still prefers the longest running registered ancestor over
a missing child workspace state. This keeps invocations from subdirectories
attached to the same parent workspace pod. The parent workspace remains the
mounted root, while app sessions start in the originally requested subdirectory
when it is inside that workspace. The app container also mounts the workspace at
its original host absolute path, which keeps Codex resume discovery and Git
branch grouping aligned with host-side `~/.codex` session metadata.

For linked Git worktrees, the launcher also mounts the worktree's shared Git
metadata into the app container at the absolute path recorded by the `.git`
pointer file. The same Git metadata path is exposed to the inner Codex sandbox
through `CODEX_EXTRA_ADD_DIRS`, which the runtime wrapper turns into `--add-dir`
flags for `codex`. This fixes `git status`, `git add`, and related commands from
subdirectories without switching the whole session to `danger-full-access`.

The load order is:

1. `${CODEX_CONTAINER_GLOBAL_ENV_FILE:-$HOME/.local/share/codex-container/env}`
2. `${CODEX_CONTAINER_WORKSPACE_ENV_FILE:-$WORK_DIR/.codex-container.env}`
3. each colon-separated path in `CODEX_CONTAINER_ENV_FILES`

Later env files override earlier env files. Variables already present in the
caller environment override all env files, so one-off invocations such as
`PROXY_ENABLE=1 codex.sh ...` remain strongest.

Variables named `CODEX_ENV_<NAME>` are propagated only to the Codex app
container as `<NAME>`. This keeps host/launcher variable names separate from
the names seen by Codex:

```bash
CODEX_ENV_OPENAI_API_KEY=...
```

starts the app container with `OPENAI_API_KEY` set. The original
`CODEX_ENV_OPENAI_API_KEY` name is not passed into the container. The same
mapping is also applied to later `enter` and `shell` exec sessions, including
when the workspace is selected by `--id`. In `.envrc`, this is useful with
wallet-backed secrets:

```bash
export CODEX_ENV_OPENAI_API_KEY="$(kwallet-query kdewallet -f Passwords -r OPENAI_API_KEY)"
```

For long-lived or mutating commands, the launcher copies itself to
`${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/codex-container/launcher-snapshots` and
re-execs the copy once. This protects active `start`, `spawn`, `replace`,
`respawn`, `enter`, `shell`, `rootenter`, `rootshell`, `fwenter`, `fwshell`,
copy/pull, and remove operations from subsequent edits to the source launcher.
Short read-only commands `help`, `list`, `name`, and `status` run directly.

`CODEX_ALLOWED_DOMAIN_CATEGORIES` composes the default firewall domain
allowlist from named groups. Remove whole categories for narrower environments,
or override an individual `CODEX_ALLOWED_DOMAINS_*` variable when a group needs
local tuning. `OPENAI_ALLOWED_DOMAINS` remains a full manual override; if it is
set, category composition is skipped. `EXTRA_ALLOWED_DOMAINS` appends local
one-off domains after category composition.

`build-images.sh` extracts the staged Codex package version from
`dist/codex.tgz` and saves it onto the runtime image as `codex.cli.version` and
`org.opencontainers.image.version`. When a new pod is created, the launcher
reads `codex.cli.version` from the runtime image, falls back to a one-shot
`podman run --rm --entrypoint codex <image> --version` probe if needed, queries
`${CODEX_RELEASE_API_URL}` with `curl`, and labels the pod and app container
with:

```text
codex.cli.version=<staged version>
codex.cli.latest=<latest release version>
```

The GitHub lookup is best-effort. If `curl` is missing, the request times out,
or the API is unavailable, startup continues and only the local image version
label is set. The resolved `codex.cli.version` and `codex.cli.latest` values
are also written into the workspace state directory under
`${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/codex-container/workspaces/state/<hash>/`.
Disable the lookup with `CODEX_RELEASE_CHECK_ON_SPAWN=0`.

The runtime image also carries OCI-style labels including
`org.opencontainers.image.title`, `org.opencontainers.image.description`,
`org.opencontainers.image.ref.name`, and `org.opencontainers.image.version`.
Spawned pods and app containers mirror the resolved version as
`org.opencontainers.image.version` and include
`app.kubernetes.io/name`, `app.kubernetes.io/part-of`,
`app.kubernetes.io/component`, and `app.kubernetes.io/version`.

`CODEX_ALLOWED_DOMAINS_VENDOR_OPT_IN` is intentionally not included in the
default categories because those domains are broad vendor or third-party
download surfaces. `CODEX_OMITTED_DOMAINS` records legacy preset domains that
are deliberately not allowed by default.

The firewall sidecar stores live policy state in the host runtime directory
mounted at `/etc/codex-firewall`. The app container mounts the same directory
read-only at `CODEX_FIREWALL_POLICY_DIR`, defaulting to
`/run/codex-firewall-policy`. Inside the app container, use:

```bash
codex-firewall-policy
codex-firewall-policy --json
codex-firewall-policy --path
```

The view includes configured domains and explicit IP/CIDR entries, resolved
IPv4/IPv6 destinations from the last `firewall-reload`, DNS resolver addresses,
and `mode: enforced` or `mode: lifted`.

The proxy path is split in two:

- the firewall sidecar listens on `localhost:1080` inside the pod and forwards to a Unix socket under `/run/codex-proxy`
- a dedicated `proxy` container mounts the matching host path at `/run/user/<uid>/codex-<workspace>-<hash>-proxy/proxy.sock` and relays it to `localhost:1080` on the host by default

Set `PROXY_ENABLE=1` to opt into the relay, or override
`PROXY_UPSTREAM_HOST` / `PROXY_UPSTREAM_PORT` if your host-side SOCKS service
lives somewhere else. The direct firewall path resolves allowed domains to IPs
and permits only those destinations. The proxy path permits the local proxy hop,
then the host-side SOCKS service decides the real destination policy.

Named sidecars are separate from the host relay path. Set `SIDECARS` to a
colon-separated list of sidecar IDs and define an image plus sidecar env prefix
for each ID:

```bash
SIDECARS=hcloud
SIDECAR_hcloud_IMAGE=localhost/hcloud-acl-proxy:latest
SIDECAR_hcloud_ENV_PREFIX=HCLOUD_PROXY_ENV_
CODEX_ENV_HCLOUD_ENDPOINT=http://localhost:8090/v1
CODEX_ENV_HCLOUD_TOKEN=local-proxy-token
HCLOUD_PROXY_ENV_HCLOUD_TOKEN=real-upstream-token
HCLOUD_PROXY_ENV_HCLOUD_PROXY_TOKEN=local-proxy-token
```

The launcher starts sidecars with `--pod <codex-pod>`, so the Codex app reaches
the proxy through pod-local `localhost`. Variables matching the sidecar env
prefix are passed only to that sidecar after stripping the prefix; `CODEX_ENV_*`
variables are still passed only to the Codex app. The launcher passes stripped
sidecar env names to Podman instead of putting secret values on the command
line. If the sidecar image needs extra mounts or flags, set
`SIDECAR_<id>_RUN_ARGS`. If it needs an explicit startup command, set
`SIDECAR_<id>_COMMAND`, which runs as `sh -lc`.

The primary launcher defaults to:

- `CODEX_SANDBOX_MODE=danger-full-access`
- `CODEX_APPROVAL_POLICY=on-request`

That avoids the `bwrap` path while still keeping approvals enabled. If you explicitly want the broad Codex bypass mode, set:

```bash
CODEX_DANGEROUS_BYPASS=1
```

For Podman-side experimentation, especially around networking or firewall behavior, you can inject extra arguments with:

- `PODMAN_POD_CREATE_ARGS`
- `PODMAN_FIREWALL_RUN_ARGS`
- `PODMAN_CODEX_RUN_ARGS`
- `PODMAN_EXEC_ARGS`

These are appended to the corresponding `podman pod create` or `podman run` command.

If you need to override the final in-container command entirely, use:

```bash
CONTAINER_EXEC_COMMAND="bash"
```

or for a one-off test:

```bash
PODMAN_EXEC_ARGS="--privileged" CONTAINER_EXEC_COMMAND="bash -lc 'env | sort'" ./run-in-container.sh ''
```

The launcher also pauses briefly after printing its startup summary. To change or disable that:

```bash
STARTUP_SUMMARY_HOLD_SECONDS=0
```

The firewall sidecar is managed with `podman exec`. Useful commands:

```bash
podman exec <firewall-container> firewall-list
podman exec <firewall-container> firewall-allow-domain example.com
podman exec <firewall-container> firewall-allow-address 203.0.113.7
podman exec <firewall-container> firewall-allow-address 2001:db8::7
podman exec <firewall-container> firewall-reload
podman exec <firewall-container> firewall-lift
```

`firewall-lift` removes only this prototype's `inet codex_firewall` nftables
table and records `mode: lifted` in the shared policy state. Run
`firewall-reload` to restore enforcement from the configured policy files.
