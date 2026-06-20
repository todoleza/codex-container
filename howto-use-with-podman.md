## Podman workflow

Build both images from `codex-container/`:

```bash
./gen-dist.sh
./build-images.sh
```

`gen-dist.sh` is the step that stages `dist/codex.tgz`. `build-images.sh` now only consumes that archive; it does not run `pnpm`, rebuild the package, or repack anything on its own.

The runtime build is generated from `Dockerfile.in`. Sorted
`container-deps/*.dnf` drop-ins become separate DNF install layers, and
`build-images.sh` enables builder layer caching explicitly. It also mounts a
persistent DNF cache from `.build-cache/dnf-fedora-44` by default. The default
builder is `buildah bud`; set `CONTAINER_CLI=podman` to use Podman as an
override. Override the DNF cache location with
`DNF_CACHE_DIR=/path/to/cache ./build-images.sh`. The mounted DNF cache reduces
package downloads, while the builder layer cache is what skips unchanged DNF
install steps.

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
- propagates `CODEX_WORKDIR`, `CODEX_SANDBOX_MODE`, `CODEX_APPROVAL_POLICY`, and `CODEX_DANGEROUS_BYPASS` into the app container
- mounts the live firewall policy into the app container read-only and exposes it through `codex-firewall-policy`
- prints a short startup summary including the current Codex sandbox/approval policy and domain allowlist

The runtime image includes a `codex` wrapper in `/usr/local/bin`. Any `codex`
process started inside the app container gets the propagated sandbox and
approval defaults unless the command line already sets them. The image also
installs a shell profile hook that changes interactive shells into
the preserved `/app<host-path>` mount, so Codex sees a stable absolute path.

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
./run-in-container.sh --id 1 fwenter
./run-in-container.sh --id parent-leaf fwshell firewall-list
./run-in-container.sh --id 1 copy ./local.txt notes/local.txt
./run-in-container.sh --id parent-leaf pull notes/out.txt ./out.txt
./run-in-container.sh --id 1 replace --model gpt-5
./run-in-container.sh rm parent-leaf
```

`spawn` starts the workspace pod in the background and exits. `enter` runs an
interactive TTY command in the preserved `/app<host-path>` mount, defaulting to
`bash`.
`shell` keeps stdin open but does not allocate a TTY, so `shell pwd` prints
that absolute path. `fwenter` and `fwshell` do the same TTY and non-TTY
operations in the firewall container; `fwenter` defaults to `bash` and
`fwshell` requires a command. `copy`/`push` copy host paths into the container;
`pull`/`fetch` copy container paths out. Relative container copy paths resolve
under the same preserved mount; local copy paths such as `./file` are resolved
to absolute host paths before calling `podman cp`.

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
an explicit launcher command, it offers to enter the existing container, replace
it, or cancel. `replace` kills any existing workspace pod before normal startup.
If there is nothing to kill, it prints that and continues.

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
CODEX_FIREWALL_POLICY_DIR=/run/codex-firewall-policy
FIREWALL_POLICY_RUNTIME_DIR_HOST=/run/user/$(id -u)/codex-<workspace>-<hash>-policy
CODEX_SANDBOX_MODE=danger-full-access
CODEX_APPROVAL_POLICY=on-request
CODEX_DANGEROUS_BYPASS=0
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

`CODEX_ALLOWED_DOMAIN_CATEGORIES` composes the default firewall domain
allowlist from named groups. Remove whole categories for narrower environments,
or override an individual `CODEX_ALLOWED_DOMAINS_*` variable when a group needs
local tuning. `OPENAI_ALLOWED_DOMAINS` remains a full manual override; if it is
set, category composition is skipped. `EXTRA_ALLOWED_DOMAINS` appends local
one-off domains after category composition.

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
